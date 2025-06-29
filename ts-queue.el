;;; ts-queue --- Thread-safe O(1) queues -*- lexical-binding: t -*-

;; Based on https://gist.github.com/jordonbiondo/d3679eafbe9e99a5dff1 and
;; queue.el in ELPA

(require 'cl-lib)
(require 'cl-macs)
(require 'ert)
(require 'fifo)

(cl-defstruct (qsem
               (:copier nil)
               (:constructor qsem-new
                             (&key
                              (name "qsem")
                              (mutex (make-mutex name))
                              (ready (make-condition-variable mutex name))
                              (size 1)
                              (avail size))))
  name mutex ready size avail)

(defun qsem-acquire (qsem)
  (ts-queue--debug "qsem-acquire..1 %S" (qsem-name qsem))
  (with-mutex (qsem-mutex qsem)
    (ts-queue--debug "qsem-acquire..2 %S" (qsem-name qsem))
    (while (= (qsem-avail qsem) 0)
      (ts-queue--debug "qsem-acquire..3 %S" (qsem-name qsem))
      (condition-wait (qsem-ready qsem)))
    (ts-queue--debug "qsem-acquire..4 %S %S" (qsem-name qsem) (qsem-avail qsem))
    ;; (should (> (qsem-avail qsem) 0))
    (ts-queue--debug "qsem-acquire..5 %S" (qsem-name qsem))
    (cl-decf (qsem-avail qsem))
    (ts-queue--debug "qsem-acquire..done %S" (qsem-name qsem))))

(defun qsem-release (qsem)
  (ts-queue--debug "qsem-release..1 %S" (qsem-name qsem))
  (with-mutex (qsem-mutex qsem)
    (ts-queue--debug "qsem-release..2 %S" (qsem-name qsem))
    (cl-incf (qsem-avail qsem))
    (ts-queue--debug "qsem-release..3 %S %S" (qsem-name qsem) (qsem-avail qsem))
    ;; (should (<= (qsem-avail qsem) (qsem-size qsem)))
    (ts-queue--debug "qsem-release..4 %S" (qsem-name qsem))
    (condition-notify (qsem-ready qsem))
    (ts-queue--debug "qsem-release..done %S" (qsem-name qsem))))

(defmacro with-qsem (qsem &rest body)
  `(unwind-protect
       (progn
         (qsem-acquire ,qsem)
         ,@body)
     (qsem-release ,qsem)))

(cl-defstruct
    (ts-queue
     (:copier nil)
     (:constructor nil)
     (:constructor ts-queue-create
                   (&key
                    (name "queue")
                    (mutex (make-mutex name))
                    (pushed (make-condition-variable mutex name))
                    (fifo (make-fifo))
                    (size 256)
                    &aux
                    (slots (qsem-new :name name
                                     :size size
                                     :avail (- size (fifo-length fifo)))))))
  name mutex pushed fifo slots)

(defvar ts-queue-debug nil)

(defsubst ts-queue--debug (&rest args)
  (when ts-queue-debug (apply #'message args))
  (should (null (thread-last-error t))))

(defun ts-queue-push (queue elem)
  (ts-queue--debug "ts-queue-push..1 %S %S" (ts-queue-name queue) elem)
  (unless (eq elem :ts-queue--eof)
    (qsem-acquire (ts-queue-slots queue)))
  (ts-queue--debug "ts-queue-push..2 %S %S" (ts-queue-name queue) elem)
  (with-mutex (ts-queue-mutex queue)
    (ts-queue--debug "ts-queue-push..3 %S %S" (ts-queue-name queue) elem)
    (fifo-push (ts-queue-fifo queue) elem)
    (ts-queue--debug "ts-queue-push..4 %S %S" (ts-queue-name queue) elem)
    (condition-notify (ts-queue-pushed queue) t)
    (ts-queue--debug "ts-queue-push..5 %S %S" (ts-queue-name queue) elem)
    )
  (ts-queue--debug "ts-queue-push..6 %S %S" (ts-queue-name queue) elem)
  (thread-yield)
  (ts-queue--debug "ts-queue-push..done %S %S" (ts-queue-name queue) elem))

(defun ts-queue-close (queue)
  (ts-queue--debug "ts-queue-close..1 %S" (ts-queue-name queue))
  (ts-queue-push queue :ts-queue--eof)
  (ts-queue--debug "ts-queue-close..done %S" (ts-queue-name queue))
  )

(defun ts-queue-at-eof (value)
  (eq :ts-queue--eof value))

(defun ts-queue-pop (queue)
  (ts-queue--debug "ts-queue-pop..1 %S" (ts-queue-name queue))
  (with-mutex (ts-queue-mutex queue)
    (ts-queue--debug "ts-queue-pop..2 %S" (ts-queue-name queue))
    (while (fifo-empty-p (ts-queue-fifo queue))
      (ts-queue--debug "ts-queue-pop..3 %S, slots available = %S"
                       (ts-queue-name queue)
                       (qsem-avail (ts-queue-slots queue)))
      (condition-wait (ts-queue-pushed queue)))
    (ts-queue--debug "ts-queue-pop..4 %S" (ts-queue-name queue))
    (prog1
        (fifo-pop (ts-queue-fifo queue))
      (ts-queue--debug "ts-queue-pop..5 %S" (ts-queue-name queue))
      (qsem-release (ts-queue-slots queue))
      (ts-queue--debug "ts-queue-pop..done %S" (ts-queue-name queue)))
    ))

(defun ts-queue-peek (queue)
  "Peek at the queue.
Returns one of two cons cells:
  (t . value)
  (nil . nil)"
  (ts-queue--debug "ts-queue-peek..1 %S" (ts-queue-name queue))
  (with-mutex (ts-queue-mutex queue)
    (ts-queue--debug "ts-queue-peek..2 %S" (ts-queue-name queue))
    (prog1
        (if (fifo-empty-p (ts-queue-fifo queue))
            '(nil . nil)
          (cons t (fifo-head (ts-queue-fifo queue))))
      (ts-queue--debug "ts-queue-peek..done %S" (ts-queue-name queue)))))

(defun ts-queue-closed-p (queue)
  (ts-queue--debug "ts-queue-closed-p..1 %S" (ts-queue-name queue))
  (let ((head (ts-queue-peek queue)))
    (ts-queue--debug "ts-queue-closed-p..2 %S" (ts-queue-name queue))
    (prog1
        (or (null (car head))
            (ts-queue-at-eof (cdr head)))
      (ts-queue--debug "ts-queue-closed-p..3 %S" (ts-queue-name queue)))))

(ert-deftest ts-queue-push-test ()
  (let ((queue (ts-queue-create :fifo (fifo-from-list '(1 2 3)))))
    (ts-queue-push queue 4)
    (should (equal '(1 2 3 4) (fifo-to-list (ts-queue-fifo queue))))))

(ert-deftest ts-queue-pop-test ()
  (let ((queue (ts-queue-create :fifo (fifo-from-list '(1 2 3)))))
    (should (= 1 (ts-queue-pop queue)))
    (should (equal '(2 3) (fifo-to-list (ts-queue-fifo queue))))))

(ert-deftest ts-queue-push-pop-test ()
  (let ((queue (ts-queue-create)))
    (ts-queue-push queue 1)
    (ts-queue-push queue 2)
    (ts-queue-push queue 3)
    (ts-queue-close queue)
    (should (= 1 (ts-queue-pop queue)))
    (should (= 2 (ts-queue-pop queue)))
    (should (= 3 (ts-queue-pop queue)))
    (should (ts-queue-closed-p queue))))

(ert-deftest ts-queue-with-multi-threads-test ()
  (let* ((queue (ts-queue-create))
         (foo (make-thread
               #'(lambda ()
                   (ts-queue-push queue 1)
                   (ts-queue-push queue 2)
                   (ts-queue-push queue 3))
               "foo"))
         (bar (make-thread
               #'(lambda ()
                   (should (= 1 (ts-queue-pop queue)))
                   (should (= 2 (ts-queue-pop queue)))
                   (should (= 3 (ts-queue-pop queue))))
               "bar")))
    (thread-join foo)
    (thread-join bar)
    (should (null (thread-last-error t)))))

(provide 'ts-queue)

;;; ts-queue.el ends here

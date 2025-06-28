;;; ts-queue --- Thread-safe O(1) queues -*- lexical-binding: t -*-

;; Based on https://gist.github.com/jordonbiondo/d3679eafbe9e99a5dff1 and
;; queue.el in ELPA

(require 'cl-lib)
(require 'cl-macs)
(require 'ert)
(require 'fifo)

(cl-defstruct
    (ts-queue
     (:copier nil)
     (:constructor nil)
     (:constructor ts-queue-create
                   (&key
                    (name "queue")
                    (mutex (make-mutex name))
                    (pushed (make-condition-variable mutex name))
                    (fifo (make-fifo)))))
  name mutex pushed fifo)

(defvar ts-queue-debug nil)

(defun ts-queue-push (queue elem)
  (when ts-queue-debug (message "ts-queue-push..1 %S" queue))
  (with-mutex (ts-queue-mutex queue)
    (when ts-queue-debug (message "ts-queue-push..2 %S" queue))
    (fifo-push (ts-queue-fifo queue) elem)
    (when ts-queue-debug (message "ts-queue-push..3 %S" queue))
    (condition-notify (ts-queue-pushed queue) t)
    (when ts-queue-debug (message "ts-queue-push..4 %S" queue))
    )
  (when ts-queue-debug (message "ts-queue-push..5 %S" queue))
  (thread-yield))

(defun ts-queue-close (queue)
  (when ts-queue-debug (message "ts-queue-close..1 %S" queue))
  (ts-queue-push queue :ts-queue--eof)
  (when ts-queue-debug (message "ts-queue-close..2 %S" queue))
  )

(defun ts-queue-at-eof (value)
  (eq :ts-queue--eof value))

(defun ts-queue-pop (queue)
  (when ts-queue-debug (message "ts-queue-pop..1 %S" queue))
  (with-mutex (ts-queue-mutex queue)
    (when ts-queue-debug (message "ts-queue-pop..2 %S" queue))
    (while (fifo-empty-p (ts-queue-fifo queue))
      (when ts-queue-debug (message "ts-queue-pop..3 %S" queue))
      (condition-wait (ts-queue-pushed queue)))
    (when ts-queue-debug (message "ts-queue-pop..4 %S" queue))
    (fifo-pop (ts-queue-fifo queue))))

(defun ts-queue-peek (queue)
  "Peek at the queue.
Returns one of two cons cells:
  (t . value)
  (nil . nil)"
  (when ts-queue-debug (message "ts-queue-peek..1 %S" queue))
  (with-mutex (ts-queue-mutex queue)
    (when ts-queue-debug (message "ts-queue-peek..2 %S" queue))
    (if (fifo-empty-p (ts-queue-fifo queue))
        '(nil . nil)
      (cons t (fifo-head (ts-queue-fifo queue))))))

(defun ts-queue-closed-p (queue)
  (when ts-queue-debug (message "ts-queue-closed-p..1 %S" queue))
  (let ((head (ts-queue-peek queue)))
    (or (null (car head))
        (ts-queue-at-eof (cdr head)))))

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
                   (ts-queue-push queue 3))))
         (bar (make-thread
               #'(lambda ()
                   (should (= 1 (ts-queue-pop queue)))
                   (should (= 2 (ts-queue-pop queue)))
                   (should (= 3 (ts-queue-pop queue)))))))
    (thread-join foo)
    (thread-join bar)
    (should (null (thread-last-error t)))))

(provide 'ts-queue)

;;; ts-queue.el ends here

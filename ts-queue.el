;;; ts-queue.el --- Thread-safe O(1) queues -*- lexical-binding: t -*-

;; Based on https://gist.github.com/jordonbiondo/d3679eafbe9e99a5dff1 and
;; queue.el in ELPA

(require 'cl-lib)
(require 'cl-macs)
(require 'fifo)
(require 'qsem)

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
  (when ts-queue-debug (apply #'message args)))

(defun ts-queue-push (queue elem)
  (ts-queue--debug "ts-queue-push..1 %S %S" (ts-queue-name queue) elem)
  (unless (eq elem :ts-queue--eof)
    (qsem-acquire (ts-queue-slots queue)))
  (ts-queue--debug "ts-queue-push..2 %S %S" (ts-queue-name queue) elem)
  (with-mutex (ts-queue-mutex queue)
    (fifo-push (ts-queue-fifo queue) elem)
    (ts-queue--debug "ts-queue-push..4 %S %S" (ts-queue-name queue) elem)
    (condition-notify (ts-queue-pushed queue) t)
    (ts-queue--debug "ts-queue-push..5 %S %S" (ts-queue-name queue) elem))
  (thread-yield)
  (ts-queue--debug "ts-queue-push..done %S %S" (ts-queue-name queue) elem))

(defun ts-queue-close (queue)
  (ts-queue--debug "ts-queue-close..1 %S" (ts-queue-name queue))
  (ts-queue-push queue :ts-queue--eof)
  (ts-queue--debug "ts-queue-close..done %S" (ts-queue-name queue)))

(defun ts-queue-at-eof (value)
  (eq :ts-queue--eof value))

(defun ts-queue-pop (queue)
  (ts-queue--debug "ts-queue-pop..1 %S" (ts-queue-name queue))
  (with-mutex (ts-queue-mutex queue)
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
      (ts-queue--debug "ts-queue-pop..done %S" (ts-queue-name queue)))))

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

(provide 'ts-queue)

;;; ts-queue.el ends here

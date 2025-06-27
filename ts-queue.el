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
                   (&key (mutex (make-mutex))
                         (pushed (make-condition-variable mutex))
                         (fifo (make-fifo)))))
  mutex pushed fifo)

(defun ts-queue-push (queue elem)
  ;; (message "ts-queue-push: queue: %S, elem: %S" queue elem)
  (with-mutex (ts-queue-mutex queue)
    ;; (message "ts-queue-push: step..2")
    (fifo-push (ts-queue-fifo queue) elem)
    ;; (message "ts-queue-push: queue: %S, condition-notify: %S"
    ;;          queue (ts-queue-pushed queue))
    (condition-notify (ts-queue-pushed queue) t)
    ;; (message "ts-queue-push: step..3")
    )
  ;; (message "ts-queue-push: step..4")
  (thread-yield))

(defun ts-queue-close (queue)
  (ts-queue-push queue :ts-queue--eof))

(defun ts-queue-at-eof (value)
  (eq :ts-queue--eof value))

(defun ts-queue-pop (queue)
  ;; (message "ts-queue-pop: queue: %S" queue)
  (with-mutex (ts-queue-mutex queue)
    ;; (message "ts-queue-pop: step..2")
    (while (fifo-empty-p (ts-queue-fifo queue))
      ;; (message "ts-queue-pop: step..3")
      (accept-process-output nil nil 100)
      ;; The queue may have been written to by another thread while we were
      ;; (message "ts-queue-pop: step..4")
      (when (fifo-empty-p (ts-queue-fifo queue))
        ;; (message "ts-queue-pop: queue: %S, condition-wait: %S..."
        ;;          queue (ts-queue-pushed queue))
        (condition-wait (ts-queue-pushed queue))
        ;; (message "ts-queue-pop: queue: %S, condition-wait: %S...done"
        ;;          queue (ts-queue-pushed queue))
        ))
    ;; (message "ts-queue-pop: step..5")
    (let ((x (fifo-pop (ts-queue-fifo queue))))
      ;; (message "ts-queue-pop: queue: %S, popped: %S" queue x)
      x)))

(defun ts-queue-peek (queue)
  ;; (message "ts-queue-peek: queue: %S" queue)
  (with-mutex (ts-queue-mutex queue)
    ;; (message "ts-queue-peek: step..2")
    (while (fifo-empty-p (ts-queue-fifo queue))
      ;; (message "ts-queue-peek: step..3")
      ;; Based on debugging this appears to free the mutex and allow another
      ;; thread to run, acquire it, and change the contents of the fifo, which
      ;; is why we have to test it again after.
      (accept-process-output nil nil 100)
      ;; (message "ts-queue-peek: step..4")
      (when (fifo-empty-p (ts-queue-fifo queue))
        ;; (message "ts-queue-peek: queue: %S, condition-wait: %S..."
        ;;          queue (ts-queue-pushed queue))
        (condition-wait (ts-queue-pushed queue))
        ;; (message "ts-queue-peek: queue: %S, condition-wait: %S...done"
        ;;          queue (ts-queue-pushed queue))
        ))
    ;; Ensure condition is still there for next pop or peek
    ;; (message "ts-queue-peek: queue: %S, condition-notify: %S"
    ;;          queue (ts-queue-pushed queue))
    (condition-notify (ts-queue-pushed queue) t)
    ;; (message "ts-queue-peek: step..5")
    (let ((x (fifo-head (ts-queue-fifo queue))))
      ;; (message "ts-queue-peek: queue: %S, head: %S" queue x)
      x)))

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
    (should (ts-queue-at-eof (ts-queue-pop queue)))))

(ert-deftest ts-queue-with-multi-threads-test ()
  (let* ((queue (ts-queue-create))
         (foo (make-thread
               #'(lambda ()
                   ;; (message "pushing 1.. %S" queue)
                   (ts-queue-push queue 1)
                   ;; (message "pushing 2.. %S" queue)
                   (ts-queue-push queue 2)
                   ;; (message "pushing 3.. %S" queue)
                   (ts-queue-push queue 3)
                   ;; (message "foo is done")
                   )))
         (bar (make-thread
               #'(lambda ()
                   ;; (message "pulling 1.. %S" queue)
                   (should (= 1 (ts-queue-pop queue)))
                   ;; (message "pulling 2.. %S" queue)
                   (should (= 2 (ts-queue-pop queue)))
                   ;; (message "pulling 3.. %S" queue)
                   (should (= 3 (ts-queue-pop queue)))
                   ;; (message "bar is done")
                   ))))
    ;; (message "joining foo")
    (thread-join foo)
    ;; (message "joining bar")
    (thread-join bar)
    (should (null (thread-last-error t)))))

(provide 'ts-queue)

;;; ts-queue.el ends here

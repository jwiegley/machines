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
  (with-mutex (ts-queue-mutex queue)
    (fifo-push (ts-queue-fifo queue) elem)
    (condition-notify (ts-queue-pushed queue) t))
  (thread-yield))

(defun ts-queue-close (queue)
  (ts-queue-push queue :ts-queue--eof))

(defun ts-queue-at-eof (value)
  (eq :ts-queue--eof value))

(defun ts-queue-pop (queue)
  (with-mutex (ts-queue-mutex queue)
    (while (fifo-empty-p (ts-queue-fifo queue))
      (condition-wait (ts-queue-pushed queue)))
    (fifo-pop (ts-queue-fifo queue))))

(defun ts-queue-peek (queue)
  "Peek at the queue.
Returns one of two cons cells:
  (t . value)
  (nil . nil)"
  (with-mutex (ts-queue-mutex queue)
    (if (fifo-empty-p (ts-queue-fifo queue))
        '(nil . nil)
      (cons t (fifo-head (ts-queue-fifo queue))))))

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

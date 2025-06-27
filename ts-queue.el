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
    (condition-notify (ts-queue-pushed queue)))
  (thread-yield))

(defun ts-queue-close (queue)
  (ts-queue-push queue :ts-queue--eof))

(defun ts-queue-at-eof (value)
  (eq :ts-queue--eof value))

(defun ts-queue-pop (queue)
  (with-mutex (ts-queue-mutex queue)
    (let ((fifo (ts-queue-fifo queue)))
      (while (fifo-empty-p fifo)
        (condition-wait (ts-queue-pushed queue)))
      (fifo-pop fifo))))

(defun ts-queue-peek (queue)
  (with-mutex (ts-queue-mutex queue)
    (let ((fifo (ts-queue-fifo queue)))
      (while (fifo-empty-p fifo)
        (condition-wait (ts-queue-pushed queue)))
      (fifo-head fifo))))

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

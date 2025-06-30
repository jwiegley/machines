;;; test-ts-queue --- Tests for ts-queue -*- lexical-binding: t -*-

(require 'ts-queue)
(require 'ert)

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

(provide 'test-ts-queue)

;;; test-ts-queue.el ends here

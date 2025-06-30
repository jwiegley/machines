;;; test-fifo --- Tests for fifo -*- lexical-binding: t -*-

(require 'fifo)
(require 'ert)

(ert-deftest fifo-push-test ()
  (let ((fifo (fifo-from-list '(1 2 3))))
    (fifo-push fifo 4)
    (should (equal '(1 2 3 4) (fifo-to-list fifo)))))

(ert-deftest fifo-pop-test ()
  (let ((fifo (fifo-from-list '(1 2 3))))
    (should (= 1 (fifo-pop fifo)))
    (should (equal '(2 3) (fifo-to-list fifo)))))

(provide 'test-fifo)

;;; test-fifo.el ends here

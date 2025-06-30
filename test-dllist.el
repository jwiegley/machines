;;; test-dllist --- Tests for dllist -*- lexical-binding: t -*-

(require 'dllist)
(require 'ert)

(ert-deftest dllist-to-from-list-test ()
  (let ((x '(1 2 nil 4 5)))
    (should (equal x (dllist-to-list (dllist-from-list x))))))

(ert-deftest dllist-to-from-to-from-list-test ()
  (let ((x '(1 2 nil 4 5)))
    (should (equal x (dllist-to-list
                      (dllist-from-list
                       (dllist-to-list
                        (dllist-from-list x))))))))

(ert-deftest dllist-nth-test ()
  (let ((x (dllist-from-list '(1 2 nil 4 5))))
    (should (= 2 (dllist-value (dllist-nth x 1))))
    (should (= 4 (dllist-value (dllist-nth x 3))))))

(ert-deftest dllist-cyclic-from-list-test ()
  (let ((x (dllist-cyclic-from-list '(1 2 nil 4 5))))
    (should (= 2 (dllist-value (dllist-nth x 1))))
    (should (= 2 (dllist-value (dllist-nth x 6))))))

(provide 'test-dllist)

;;; test-dllist.el ends here

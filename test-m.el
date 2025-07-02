;;; test-m --- Tests for m.el -*- lexical-binding: t -*-

;;; Commentary:

;;; Code:

(require 'm)
(require 'm-test)
(require 'ert)

(m--test m-identity
  (let ((m (m-identity)))
    (m-send m 1)
    (m-send m 2)
    (m-send m 3)
    (m-send-eof m)
    (should (= 1 (m-await m)))
    (should (= 2 (m-await m)))
    (should (= 3 (m-await m)))
    (should (m-output-closed-p m))
    (m-stop m)))

(m--test m-compose-identities
  (let ((m (m-compose (m-identity) (m-identity))))
    (m-send m 1)
    (m-send m 2)
    (m-send m 3)
    (m-send-eof m)
    (should (= 1 (m-await m)))
    (should (= 2 (m-await m)))
    (should (= 3 (m-await m)))
    (should (m-output-closed-p m))
    (m-stop m)))

(m--test m-iterator
  (m--debug "m-iterator-test..1")
  (let ((m (m-iterator
            (funcall
             (iter-lambda ()
               (m--debug "m-iterator-test..2")
               (iter-yield 1)
               (m--debug "m-iterator-test..3")
               (iter-yield 2)
               (m--debug "m-iterator-test..4")
               (iter-yield 3)
               (m--debug "m-iterator-test..5")
               )))))
    (m--debug "m-iterator-test..6")
    (should (= 1 (m-await m)))
    (m--debug "m-iterator-test..7")
    (should (= 2 (m-await m)))
    (m--debug "m-iterator-test..8")
    (should (= 3 (m-await m)))
    (m--debug "m-iterator-test..9")
    (should (m-output-closed-p m))
    (m--debug "m-iterator-test..10")
    (m-stop m)))

(m--test m-from-list-iter
  (let ((m (m-from-list-iter '(1 2 3 4 5))))
    (should (= 1 (m-await m)))
    (should (= 2 (m-await m)))
    (should (= 3 (m-await m)))
    (should (= 4 (m-await m)))
    (should (= 5 (m-await m)))
    (should (m-output-closed-p m))
    (m-stop m)))

(m--test m-from-list
  (let ((m (m-from-list '(1 2 3 4 5))))
    (should (= 1 (m-await m)))
    (should (= 2 (m-await m)))
    (should (= 3 (m-await m)))
    (should (= 4 (m-await m)))
    (should (= 5 (m-await m)))
    (should (m-output-closed-p m))
    (m-stop m)))

(m--test m-generator
  (let ((g (m-generator (m-from-list '(1 2 3)))))
    (should (= 1 (iter-next g)))
    (should (= 2 (iter-next g)))
    (should (= 3 (iter-next g)))
    (condition-case x
        (iter-next g)
      (iter-end-of-sequence
       (should (null (cdr x)))))))

(m--test m-take
  (let ((m (m-take 2 (m-from-list '(1 2 3 4 5)))))
    (m--debug "m-take-test..1")
    (should (= 1 (m-await m)))
    (m--debug "m-take-test..2")
    (should (= 2 (m-await m)))
    (m--debug "m-take-test..3")
    (should (m-output-closed-p m))
    (m--debug "m-take-test..4")
    (m-stop m)))

(m--test m-head
  (let ((m (m-head (m-from-list '(1 2 3 4 5)))))
    (should (= 1 (m-await m)))
    (should (m-output-closed-p m))
    (m-stop m)))

(m--test m-drop
  (let ((m (m-drop 2 (m-from-list '(1 2 3 4 5)))))
    (m--debug "m-drop-test..1")
    (should (= 3 (m-await m)))
    (m--debug "m-drop-test..2")
    (should (= 4 (m-await m)))
    (m--debug "m-drop-test..3")
    (should (= 5 (m-await m)))
    (m--debug "m-drop-test..4")
    (should (m-output-closed-p m))
    (m-stop m)))

(m--test m-fibonacci
  (let ((m (m-take 6 (m-fibonacci))))
    (m--debug "m-fibonacci-test..1")
    (should (= 1 (m-await m)))
    (m--debug "m-fibonacci-test..2")
    (should (= 1 (m-await m)))
    (m--debug "m-fibonacci-test..3")
    (should (= 2 (m-await m)))
    (m--debug "m-fibonacci-test..4")
    (should (= 3 (m-await m)))
    (m--debug "m-fibonacci-test..5")
    (should (= 5 (m-await m)))
    (m--debug "m-fibonacci-test..6")
    (should (= 8 (m-await m)))
    (m--debug "m-fibonacci-test..7")
    (should (m-output-closed-p m))
    (m--debug "m-fibonacci-test..8")
    (m-stop m)))

(m--test m-fibonacci-iter
  (let ((m (m-take 6 (m-fibonacci-iter))))
    (m--debug "m-fibonacci-iter-test..1")
    (should (= 1 (m-await m)))
    (m--debug "m-fibonacci-iter-test..2")
    (should (= 1 (m-await m)))
    (m--debug "m-fibonacci-iter-test..3")
    (should (= 2 (m-await m)))
    (m--debug "m-fibonacci-iter-test..4")
    (should (= 3 (m-await m)))
    (m--debug "m-fibonacci-iter-test..5")
    (should (= 5 (m-await m)))
    (m--debug "m-fibonacci-iter-test..6")
    (should (= 8 (m-await m)))
    (m--debug "m-fibonacci-iter-test..7")
    (should (m-output-closed-p m))
    (m--debug "m-fibonacci-iter-test..8")
    (m-stop m)))

(m--test m-for
  (m-for (m-from-list '(1 2 3))
    #'(lambda (x)
        (should (>= x 1))
        (should (<= x 3)))))

(m--test m-map
  (let ((m (m-map #'1+ (m-from-list '(1 2 3)))))
    (should (= 2 (m-await m)))
    (should (= 3 (m-await m)))
    (should (= 4 (m-await m)))
    (should (m-output-closed-p m))
    (m-stop m)))

(m--test m-filter
  (let ((m (m-filter #'cl-evenp (m-from-list '(1 2 3)))))
    (should (= 2 (m-await m)))
    (should (m-output-closed-p m))
    (m-stop m)))

(m--test m-funcall
  (let ((m (m-funcall #'+ :combine (apply-partially #'cl-reduce #'+))))
    (m-send m 1)
    (m-send m 2)
    (m-send m 3)
    (m-send-eof m)
    (should (= 6 (m-await m)))
    (should (m-output-closed-p m))
    (m-stop m)))

;; (m--test m-funcall-bad
;;   (let ((m (m-funcall #'+++ :combine (apply-partially #'cl-reduce #'+))))
;;     (m-send m 1)
;;     (m-send m 2)
;;     (m-send m 3)
;;     (m-send-eof m)
;;     (should-error (= 6 (m-await m)) :type 'void-function)
;;     (m-clear m)
;;     (m-stop m)))

;; (m--test m-process
;;   (let ((m (m-process "cat")))
;;     (m-send m "Hello\n")
;;     (m-send-eof m)
;;     (should (string= "Hello\n" (m-await m)))
;;     (should (m-output-closed-p m))
;;     (m-stop m)))

;; (m--test m-process-drain
;;   (let ((m (m-process "echo" "Hello there")))
;;     (thread-last
;;       (m-source m)
;;       (m-drain)
;;       (mapconcat #'identity)
;;       (string= "Hello there\n")
;;       should)
;;     (m-stop m)))

;; (m--test m-process-compose
;;   (let ((m (m-compose (m-process "grep" "--line-buffered" "foo")
;;                       (m-process "wc" "-l"))))
;;     (m-send m "foo\n")
;;     (m-send m "bar\n")
;;     (m-send m "foo\n")
;;     (m-send-eof m)
;;     (should (string= "2\n" (m-await m)))
;;     (should (m-output-closed-p m))
;;     (m-stop m)))

(provide 'test-m)

;;; test-m.el ends here

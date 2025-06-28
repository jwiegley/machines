;;; m-gptel --- GPTel machines -*- lexical-binding: t -*-

;;; Commentary:

;;; Code:

(require 'm)

(require 'gptel)
(require 'gptel-curl)
(require 'gptel-openai)

(defun m-gptel (&optional prompt)
  "Create a machine from a process. See `start-process' for details."
  (let ((input (ts-queue-create))
        (output (ts-queue-create)))
    (m-create
     :input input
     :output output
     :thread
     (make-thread
      #'(lambda ()
          (with-temp-buffer
            (setq gptel-api-key (getenv "LITELLM_API_KEY"))
            (let ((gptel-backend
                   (gptel-make-openai "LiteLLM"
                     :host "vulcan"
                     :protocol "http"
                     :endpoint "/litellm/v1/chat/completions"
                     :stream t
                     :models '((hera/Qwen3-30B-A3B
                                :description ""
                                :capabilities (media tool json url)))
                     :header
                     (lambda () `(("x-api-key"         . ,gptel-api-key)
                             ("x-litellm-timeout" . "7200")
                             ("x-litellm-tags"    . "m")))))
                  (gptel-use-context 'user)
                  (gptel-prompt-transform-functions
                   '(gptel--transform-add-context))
                  completed)
              (cl-loop for str = (ts-queue-pop input)
                       until (ts-queue-at-eof str)
                       do (insert str))
              (insert ?\n ?\n)
              (insert prompt)
              (gptel-request (buffer-string)
                :callback
                #'(lambda (response info)
                    (cond ((stringp response)
                           (ts-queue-push output response))
                          ((eq t response)
                           (ts-queue-close output)
                           (setq completed t))))
                :stream t)
              (while (not completed)
                (accept-process-output nil nil 100)))))))))

(ert-deftest m-gptel-test ()
  (let ((m (m-compose
            (m-process "cat")
            (m-gptel "Answer the question, please. /no_think"))))
    (m-send m "What is the weather like in Sacramento?")
    (m-close-input m)
    (should (null (thread-last-error t)))
    (should (string-match-p "Sacramento"
                            (mapconcat #'identity (m-drain m))))))


(provide 'm-gptel)

;;; m-gptel.el ends here

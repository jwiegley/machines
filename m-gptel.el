;;; m-gptel --- GPTel machines -*- lexical-binding: t -*-

;;; Commentary:

;;; Code:

(require 'm)
(require 'm-test)

(add-to-list 'load-path "~/.emacs.d/lisp/gptel")

(require 'gptel)
(require 'gptel-curl)
(require 'gptel-openai)

(defun m-gptel (&optional prompt)
  "Create a machine from a process. See `start-process' for details."
  (m-basic-machine "m-gptel"
    #'(lambda (m)
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

            (m--debug "m-gptel..1")
            (cl-loop for str = (m--next-input m)
                     until     (or (m-eof-p str)
                                   (m-stopped-p m))
                     do        (insert str))
            (insert ?\n ?\n prompt)

            (gptel-request (buffer-string)
              :callback
              #'(lambda (response info)
                  (cond ((stringp response)
                         (m-yield m response))
                        ((eq t response)
                         (m-yield-eof m)
                         (setq completed t))))
              :stream t)

            (while (and (not completed)
                        (not (m-stopped-p m)))
              (thread-yield)
              (accept-process-output nil nil 100)))))))

(m--test m-gptel
  (let ((m (m-compose (m-process "cat")
                      (m-gptel "Answer the question, please. /no_think"))))
    (m-send m "What is the weather like in Sacramento?")
    (m-send-eof m)
    (should (string-match-p "Sacramento"
                            (mapconcat #'identity (m-drain m))))
    (m-stop m)))

(provide 'm-gptel)

;;; m-gptel.el ends here

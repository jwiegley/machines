;;; m --- Composible, asynchronous streaming machines -*- lexical-binding: t -*-

;;; Commentary:

;;; Code:

(require 'ts-queue)

(defun m--drain-queue (input)
  "Drain the INPUT queue and return the list of its values."
  (cl-loop for x = (ts-queue-pop input)
           until (ts-queue-at-eof x)
           collect x))

(defun m--connect (input output)
  "Drain the INPUT queue into the OUTPUT queue."
  (cl-loop for x = (ts-queue-pop input)
           until (ts-queue-at-eof x)
           do (ts-queue-push output x)
           finally (ts-queue-close output)))

(cl-defstruct
    (machine
     (:copier nil)
     (:constructor nil)
     (:constructor
      m-create
      (&key (input (ts-queue-create))
            (output (ts-queue-create))
            (thread (make-thread
                     #'(lambda () (m--connect input output)))))))
  "Machines map INPUT to OUTPUT by executing code in THREAD.
Note that INPUT may be either a single queue or a vector of queues, it
all depends on the machine and how it draws its input. Likewise,
output may be a single queue of cons cells, for example, or a pair of
queues of car/cdr values, depending on the nature of the asynchronicity
desired.

THREAD should read from its input until the value receives yields true
when passed to `ts-queue-at-eof', while writing to its output until
finished, after which it should close the output queue using
`ts-queue-close'. At this point the thread should exit."
  input output thread)

(defun m-send (machine value)
  "Send the VALUE to the given MACHINE."
  (ts-queue-push (machine-input machine) value))

(defun m-close-input (machine)
  "Close the MACHINE's input queue."
  (ts-queue-close (machine-input machine)))

(defun m-await (machine)
  "Await the next results from the given MACHINE."
  (ts-queue-pop (machine-output machine)))

(defun m-peek (machine)
  "Await the next results from the given MACHINE."
  (ts-queue-peek (machine-output machine)))

(defun m-drain (machine)
  "Drain the output of MACHINE into a list."
  (m--drain-queue (machine-output machine)))

(defun m-output-closed-p (machine)
  "Return non-nil if the MACHINE's output queue has been closed.
This should only ever be called once, and will block until it sees the
closure token, so only call this in conditions where you know exactly
when to expect that the output is closed. Generally this is only useful
for testing."
  (ts-queue-at-eof (m-peek machine)))

(defsubst m-identity ()
  "The identity machine does nothing, just forwards input to output."
  (m-create))

(ert-deftest m-identity-test ()
  (let ((m (m-identity)))
    (m-send m 1)
    (m-send m 2)
    (m-send m 3)
    (m-close-input m)
    (should (= 1 (m-await m)))
    (should (= 2 (m-await m)))
    (should (= 3 (m-await m)))
    (should (m-output-closed-p m))))

(defun m-compose (left right)
  "Compose the LEFT machine with the RIGHT.
This operation follows monoidal laws with respect to m-identity."
  (m-create
   :input (machine-input left)
   :output (machine-output right)
   :thread (make-thread
            #'(lambda ()
                (cl-loop for xs = (m-await left)
                         do (m-send right xs))))))

(ert-deftest m-compose-identities-test ()
  (let ((m (m-compose (m-identity) (m-identity))))
    (m-send m 1)
    (m-send m 2)
    (m-send m 3)
    (m-close-input m)
    (should (= 1 (m-await m)))
    (should (= 2 (m-await m)))
    (should (= 3 (m-await m)))
    (should (m-output-closed-p m))))

;;; Example machines

(cl-defun m-funcall (func &key (combine #'identity))
  "Turn the function FUNC into a machine.
Since machine might receive their input piece-wise, the caller must
specify a function to COMBINE a list of input into a final input for
FUNC."
  (let ((input (ts-queue-create))
        (output (ts-queue-create)))
    (m-create
     :input input
     :output output
     :thread
     (make-thread
      #'(lambda ()
          (thread-last
            input
            m--drain-queue
            (funcall combine)
            (funcall func)
            (ts-queue-push output))
          (ts-queue-close output))))))

(ert-deftest m-funcall-test ()
  (let ((m (m-funcall #'+ :combine (apply-partially #'cl-reduce #'+))))
    (m-send m 1)
    (m-send m 2)
    (m-send m 3)
    (m-close-input m)
    (should (= 6 (m-await m)))
    (should (m-output-closed-p m))))

(defun m-process (program &rest program-args)
  "Create a machine from a process. See `start-process' for details."
  (let ((input (ts-queue-create))
        (output (ts-queue-create)))
    (m-create
     :input input
     :output output
     :thread
     (make-thread
      #'(lambda ()
          ;; (message "proc: starting process")
          (let* ((mutex (make-mutex))
                 (done (make-condition-variable mutex))
                 (proc
                  (make-process
                   :name "m-process"
                   :command (cons program program-args)
                   :connection-type 'pipe
                   :filter #'(lambda (_proc x)
                               ;; (message "proc: filter: %S" x)
                               (ts-queue-push output x))
                   :sentinel #'(lambda (_proc event)
                                 ;; (message "proc: sentinel: %S" event)
                                 ;; (message "proc: output: %S" output)
                                 (ts-queue-close output)
                                 ;; (message "proc: notifying mutex")
                                 (with-mutex mutex
                                   (condition-notify done))))))
            ;; (message "proc: starting loop")
            (cl-loop for str = (progn
                                 ;; (message "proc: popping...")
                                 (accept-process-output proc nil 100)
                                 (ts-queue-pop input))
                     until (progn
                             ;; (message "proc: at eof? %S" str)
                             (ts-queue-at-eof str))
                     do (progn
                          ;; (message "proc: send str: %S" str)
                          (process-send-string proc str))
                     finally (progn
                               ;; (message "proc: send eof")
                               (process-send-eof proc)))
            ;; (message "proc: waiting for termination")
            (with-mutex mutex
              (condition-wait done))
            ;; (message "proc: thread is done")
            ))))))

(ert-deftest m-process-test ()
  (let ((m (m-process "cat")))
    ;; (message "(m-send m \"Hello\\n\")")
    (m-send m "Hello\n")
    ;; (message "(m-close-input m)")
    (m-close-input m)
    ;; (message "(should (string= \"Hello\\n\" (m-await m)))")
    (should (string= "Hello\n" (m-await m)))
    ;; (message "(should (m-output-closed-p m))")
    (should (null (thread-last-error t)))
    (should (m-output-closed-p m))
    (should (null (thread-last-error t)))
    ;; (message "m-process-test completed")
    ))

(ert-deftest m-process-compoose-test ()
  (let ((m (m-compose (m-process "grep" "foo") (m-process "wc" "-l"))))
    (m-send m "foo\n")
    (m-send m "bar\n")
    (m-send m "foo\n")
    (m-close-input m)
    (should (string= "2\n" (m-await m)))
    (should (m-output-closed-p m))))

(require 'gptel)
(require 'gptel-curl)
(require 'gptel-openai)

(cl-defun m-gptel ()
  "Create a machine from a process. See `start-process' for details."
  (message "m-gptel: step 1..")
  (let* ((input (ts-queue-create))
         (output (ts-queue-create))
         (mutex (make-mutex))
         (done (make-condition-variable mutex)))
    (message "m-gptel: step 2..")
    (m-create
     :input input
     :output output
     :thread
     (make-thread
      #'(lambda ()
          (message "m-gptel: step 3..")
          (with-temp-buffer
            (setq gptel-api-key (getenv "LITELLM_API_KEY"))
            (let ((prompt (mapconcat #'identity (m--drain-queue input)))
                  (gptel-backend
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
                  completed)
              (message "m-gptel: step 4: %S" prompt)
              (gptel-request prompt
                :callback
                #'(lambda (response info)
                    (message "m-gptel: step 5: response %S info %S.."
                             response info)
                    (cond ((stringp response)
                           (message "m-gptel: step 6..")
                           (ts-queue-push output response)
                           (message "m-gptel: step 7.."))
                          ((eq t response)
                           (message "m-gptel: step 8..")
                           (ts-queue-close output)
                           (message "m-gptel: step 9..")
                           (with-mutex mutex
                             (setq completed t)
                             (condition-notify done))
                           (message "m-gptel: step 10..")
                           )))
                :buffer (current-buffer)
                :stream t)
              (message "m-gptel: step 11..")
              (with-mutex mutex
                (while (not completed)
                  (accept-process-output nil nil 100)
                  (condition-wait done)))
              (message "m-gptel: step 12.."))))))))

(ert-deftest m-gptel-test ()
  (let ((m (m-gptel)))
    (message "(m-send m \"Hello /no_think\\n\")")
    (m-send m "Hello /no_think\n")
    (message "(m-close-input m)")
    (m-close-input m)
    (message "(should (string= ...))")
    (sit-for 3)
    (should (null (thread-last-error t)))
    (should (string= "Hello! How can I assist you today?"
                     (mapconcat #'identity (m-drain m))))
    (message "m-gptel-test done")
    ))

(provide 'm)

;;; m.el ends here

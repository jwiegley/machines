;;; m --- Composible, asynchronous streaming machines -*- lexical-binding: t -*-

;;; Commentary:

;;; Code:

(require 'cl-lib)
(require 'cl-macs)
(require 'ts-queue)
(require 'generator)

(defun should-be-quiescent ()
  (should (null (delete main-thread (all-threads))))
  (should (null (process-list))))

(defsubst m--debug (&rest args)
  (when ts-queue-debug (apply #'message args))
  (should (null (thread-last-error t))))

(defun m--drain-queue (input)
  "Drain the INPUT queue and return the list of its values."
  (m--debug "m--drain-queue..1 %S" (ts-queue-name input))
  (cl-loop for x = (ts-queue-pop input)
           until (ts-queue-at-eof x)
           collect x))

(defun m--connect-queues (input output &optional func)
  "Drain the INPUT queue into the OUTPUT queue."
  (m--debug "m--connect-queues..1 %S %S %S"
            (ts-queue-name input) (ts-queue-name output) func)
  (cl-loop for x = (ts-queue-pop input)
           until (ts-queue-at-eof x)
           do (ts-queue-push output (funcall (or func #'identity) x))
           finally (ts-queue-close output)))

(cl-defstruct (machine (:copier nil))
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
  name input output thread (stop (list nil)))

(defun m-join (machine)
  "Join on the thread for MACHINE."
  (m--debug "m-join..1 %S" (machine-name machine))
  (thread-join (machine-thread machine)))

(defun m-send (machine value)
  "Send the VALUE to the given MACHINE."
  (m--debug "m-send..1 %S %S" (machine-name machine) value)
  (ts-queue-push (machine-input machine) value))

(defun m-close-input (machine)
  "Close the MACHINE's input queue."
  (m--debug "m-close-input..1 %S" (machine-name machine))
  (ts-queue-close (machine-input machine)))

(defun m-close-output (machine)
  "Close the MACHINE's input queue."
  (m--debug "m-close-output..1 %S" (machine-name machine))
  (ts-queue-close (machine-output machine)))

(defun m-await (machine)
  "Await the next results from the given MACHINE."
  (m--debug "m-await..1 %S" (machine-name machine))
  (ts-queue-pop (machine-output machine)))

(defun m-peek (machine)
  "Await the next results from the given MACHINE."
  (m--debug "m-peek..1 %S" (machine-name machine))
  (ts-queue-peek (machine-output machine)))

(defun m-drain (machine)
  "Drain the output of MACHINE into a list."
  (m--debug "m-drain..1 %S" (machine-name machine))
  (m--drain-queue (machine-output machine)))

(defun m-stop (machine)
  "Stop MACHINE, flushing any pending output first."
  (m--debug "m-drain..1 %S" (machine-name machine))
  (setcar (machine-stop machine) t)
  (m--debug "m-drain..2 %S" (machine-name machine))
  (when (m-peek machine)
    (m--debug "m-drain..3 %S" (machine-name machine))
    (ignore (m-drain machine)))
  (m--debug "m-drain..4 %S" (machine-name machine))
  (m-join machine))

(defun m-source (machine)
  "A source is a MACHINE that expects no input."
  (m--debug "m-source..1 %S" (machine-name machine))
  (prog1
      machine
    (m-close-input machine)))

(defun m-sink (machine)
  "A sink is a MACHINE that produces no output."
  (m--debug "m-sink..1 %S" (machine-name machine))
  (prog1
      machine
    (m-close-output machine)))

(defun m-fanout (machine1 machine2 &rest machines)
  "Create a machine that sends its input to all the machines.
The results are transmitted with a tag to indicate which machine they
originated from:
  (1 . value)
  (0 . value)
  (1 . value)
")

(defun m-fanin (machine1 machine2 &rest machines))

(defalias 'm-eof-p 'ts-queue-at-eof)

(defun m-output-closed-p (machine)
  "Return non-nil if the MACHINE's output queue has been closed.
This should only ever be called once, and will block until it sees the
closure token, so only call this in conditions where you know exactly
when to expect that the output is closed. Generally this is only useful
for testing."
  (m--debug "m-output-closed-p..1 %s" (machine-name machine))
  (ts-queue-closed-p (machine-output machine)))

(cl-defun m--parts (name &key no-input (input-size 256) (output-size 256))
  "Helper macro to make some parts of a machine, reducing duplicate code.
NAME is the name of the machine.
NO-INPUT should be non-nil if this machine expects no input.
INPUT-SIZE is the input queue size, if NO-INPUT is nil.
OUTPUT-SIZE is the output queue size."
  (list name
        (unless no-input
          (ts-queue-create :name (concat name " (input)")
                           :size input-size))
        (ts-queue-create :name (concat name " (output)")
                         :size output-size)))

(defsubst m-identity ()
  "The identity machine does nothing, just forwards input to output."
  (m--debug "m-identity..1")
  (cl-destructuring-bind (name input output)
      (m--parts "m-identity")
    (make-machine
     :name name
     :input input
     :output output
     :thread
     (make-thread
      #'(lambda ()
          (m--debug "m-identity..2")
          (m--connect-queues input output)
          (m--debug "m-identity..done")
          )
      name))))

(ert-deftest m-identity-test ()
  (message "m-identity-test...")
  (let ((m (m-identity)))
    (m-send m 1)
    (m-send m 2)
    (m-send m 3)
    (m-close-input m)
    (should (= 1 (m-await m)))
    (should (= 2 (m-await m)))
    (should (= 3 (m-await m)))
    (should (m-output-closed-p m))
    (m-join m))
  ;; (should-be-quiescent)
  (m--debug "m-identity-test...done"))

(defun m-compose (left right)
  "Compose the LEFT machine with the RIGHT.
This composes in the reverse order to mathematical composition: the left
machine acts on the inputs coming into the composed machine, and then
passes its outputs to the right machine.

This operation follows monoidal laws with respect to `m-identity',
making this a cartesian closed category of connected streaming machines."
  (let ((name (format "m-compose %s %s"
                      (machine-name left) (machine-name right))))
    (make-machine
     :name name
     :input (machine-input left)
     :output (machine-output right)
     :thread (make-thread
              #'(lambda ()
                  (cl-loop for x = (m-await left)
                           until (m-eof-p x)
                           do (m-send right x)
                           finally (progn
                                     (m-close-input right)
                                     (m-join left))))
              name))))

(defalias 'm-connect 'm-compose)
(defalias 'm->> 'm-compose)

(ert-deftest m-compose-identities-test ()
  (message "m-compose-identities-test...")
  (let ((m (m-compose (m-identity) (m-identity))))
    (m-send m 1)
    (m-send m 2)
    (m-send m 3)
    (m-close-input m)
    (should (= 1 (m-await m)))
    (should (= 2 (m-await m)))
    (should (= 3 (m-await m)))
    (should (m-output-closed-p m))
    (m-join m))
  ;; (should-be-quiescent)
  (m--debug "m-compose-identities-test...done"))

(defun m-iterator (iter)
  (m--debug "m-iterator..1")
  (cl-destructuring-bind (name _ output)
      (m--parts "m-iterator" :no-input t :output-size 16)
    (let ((stopped (list nil)))
      (m--debug "m-iterator..2 %S" (ts-queue-name output))
      (make-machine
       :name name
       :input nil
       :output output
       :thread
       (make-thread
        #'(lambda ()
            (m--debug "m-iterator..3 %S" (ts-queue-name output))
            (condition-case e
                (progn
                  (m--debug "m-iterator..4 %S" (ts-queue-name output))
                  ;; jww (2025-06-28): This drains the iterator eagerly. Instead
                  ;; we would like to use a bounded queue.
                  (cl-loop for x = (progn
                                     (m--debug "m-iterator..5 %S" (ts-queue-name output))
                                     (prog1
                                         (iter-next iter)
                                       (m--debug "m-iterator..6 %S" (ts-queue-name output)))
                                     )
                           until (progn
                                   (m--debug "m-iterator..7 %S stopped %S"
                                             (ts-queue-name output) stopped)
                                   (car stopped))
                           do (progn
                                (m--debug "m-iterator..8 %S %S" (ts-queue-name output) x)
                                (ts-queue-push output x)
                                (m--debug "m-iterator..9 %S %S" (ts-queue-name output) x)))
                  (m--debug "m-iterator..10"))
              (iter-end-of-sequence
               (m--debug "m-iterator..11 %S" (ts-queue-name output))
               (ts-queue-close output)
               (m--debug "m-iterator..12 %S" (ts-queue-name output))))
            (m--debug "m-iterator..done")
            )
        name)
       :stop stopped))))

(ert-deftest m-iterator-test ()
  (message "m-iterator-test...")
  (setq ts-queue-debug nil)
  (m--debug "m-iterator-test..1")
  (let ((m (m-iterator (funcall
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
    (m-join m)
    (m--debug "m-iterator-test..11")
    )
  ;; (should-be-quiescent)
  (m--debug "m-iterator-test...done"))

(defun m-from-list (xs)
  (m--debug "m-from-list..1")
  (cl-destructuring-bind (name _ output)
      (m--parts "m-from-list" :no-input t :output-size 16)
    (m--debug "m-from-list..2")
    (make-machine
     :name name
     :input nil
     :output output
     :thread
     (make-thread
      #'(lambda ()
          (m--debug "m-from-list..3")
          (dolist (x xs)
            (m--debug "m-from-list..4 %S" x)
            (ts-queue-push output x))
          (m--debug "m-from-list..5")
          (ts-queue-close output)
          (m--debug "m-from-list..done")
          )
      name))))

(ert-deftest m-from-list-test ()
  (message "m-from-list-test...")
  (let ((m (m-from-list '(1 2 3 4 5))))
    (should (= 1 (m-await m)))
    (should (= 2 (m-await m)))
    (should (= 3 (m-await m)))
    (should (= 4 (m-await m)))
    (should (= 5 (m-await m)))
    (should (m-output-closed-p m))
    (m-join m))
  ;; (should-be-quiescent)
  (m--debug "m-from-list-test...done"))

(defalias 'm-to-list 'm-drain)

(iter-defun m-generator (machine)
  ;; We cannot use `m-for' here, because it runs afoul of Emacs's detection of
  ;; the use of `iter-yield' inside a generator.
  (cl-loop for x = (m-await machine)
           until (m-eof-p x)
           do (iter-yield x)
           finally (m-join machine)))

(ert-deftest m-generator-test ()
  (message "m-generator-test...")
  (let ((g (m-generator (m-from-list '(1 2 3)))))
    (should (= 1 (iter-next g)))
    (should (= 2 (iter-next g)))
    (should (= 3 (iter-next g)))
    (condition-case x
        (iter-next g)
      (iter-end-of-sequence
       (should (null (cdr x))))))
  ;; (should-be-quiescent)
  (m--debug "m-generator-test...done"))

(defun m-take (n machine)
  "Take at most N from the given MACHINE.
If MACHINE yields fewer than N elements, this machine yields that same
number of elements."
  (m--debug "m-take..1 %s %s" n (machine-name machine))
  (let* ((name (format "m-take %s %s" n (machine-name machine)))
         (output (ts-queue-create :name (concat name " (output)"))))
    (m--debug "m-take..2 %s" name)
    (make-machine
     :name name
     :input (machine-input machine)
     :output output
     :thread
     (make-thread
      #'(lambda ()
          (m--debug "m-take..3 %s" name)
          (cl-loop for i from 1 to n
                   for x = (m-await machine)
                   until (m-eof-p x)
                   do (ts-queue-push output x)
                   finally (progn
                             (m--debug "m-take..4 %s" name)
                             (ts-queue-close output)
                             (m--debug "m-take..5 %s" name)
                             ;; (m-stop machine)
                             (m--debug "m-take..6 %s" name)
                             ))
          (m--debug "m-take..done %s" name)
          )
      name))))

(ert-deftest m-take-test ()
  (message "m-take-test...")
  (let ((m (m-take 2 (m-from-list '(1 2 3 4 5)))))
    (m--debug "m-take-test..1")
    (should (= 1 (m-await m)))
    (m--debug "m-take-test..2")
    (should (= 2 (m-await m)))
    (m--debug "m-take-test..3")
    (should (m-output-closed-p m))
    (m--debug "m-take-test..4")
    (m-join m)
    (m--debug "m-take-test..5")
    )
  ;; (should-be-quiescent)
  (m--debug "m-take-test..done"))

(defun m-head (machine)
  (m-take 1 machine))

(ert-deftest m-head-test ()
  (message "m-head-test...")
  (let ((m (m-head (m-from-list '(1 2 3 4 5)))))
    (should (= 1 (m-await m)))
    (should (m-output-closed-p m))
    (m-join m))
  ;; (should-be-quiescent)
  (m--debug "m-head-test..done"))

(defun m-drop (n machine)
  "Drop the first N elements from the given MACHINE.
If MACHINE yields fewer than N elements, this machine yields none."
  (m--debug "m-drop..1 %s %S" n (machine-name machine))
  (let* ((name (format "m-drop %s %s" n (machine-name machine)))
         (output (ts-queue-create :name (concat name " (output)"))))
    (m--debug "m-drop..2 %S" name)
    (make-machine
     :name name
     :input (machine-input machine)
     :output output
     :thread
     (make-thread
      #'(lambda ()
          (m--debug "m-drop..3 %S" name)
          (let (ended)
            (cl-loop for i from 1 to n
                     for x = (m-await machine)
                     until (and (m-eof-p x) (setq ended t)))
            (m--debug "m-drop..4 %S" name)
            (unless ended
              (cl-loop for x = (progn
                                 (m--debug "m-drop..5 %S" name)
                                 (let ((x (m-await machine)))
                                   (m--debug "m-drop..6 %S %S" name x)
                                   x))
                       until   (progn
                                 (m--debug "m-drop..7 %S %S" name x)
                                 (m-eof-p x))
                       do      (progn
                                 (m--debug "m-drop..8 %S %S" name x)
                                 (ts-queue-push output x)
                                 (m--debug "m-drop..9 %S %S" name x))
                       finally (progn
                                 (m--debug "m-drop..10 %S" name)
                                 (ts-queue-close output)
                                 (m--debug "m-drop..11 %S" name)
                                 ;; (m-stop machine)
                                 (m--debug "m-drop..12 %S" name)))))
          (m--debug "m-drop..done %S" name)
          )
      name))))

(ert-deftest m-drop-test ()
  (message "m-drop-test...")
  ;; (setq ts-queue-debug t)
  (let ((m (m-drop 2 (m-from-list '(1 2 3 4 5)))))
    (m--debug "m-drop-test..1")
    (should (= 3 (m-await m)))
    (m--debug "m-drop-test..2")
    (should (= 4 (m-await m)))
    (m--debug "m-drop-test..3")
    (should (= 5 (m-await m)))
    (m--debug "m-drop-test..4")
    (should (m-output-closed-p m)))
  ;; (should-be-quiescent)
  (m--debug "m-drop-test..done"))

(defun m-fix (func start)
  (m--debug "m-fix..1 %S %S" func start)
  (cl-destructuring-bind (name _ output)
      (m--parts (format "m-fix %S" func)
                :no-input t :output-size 1)
    (let ((stopped (list nil)))
      (m--debug "m-fix..2 %S" func)
      (make-machine
       :name name
       :input nil
       :output output
       :thread
       (make-thread
        #'(lambda ()
            (m--debug "m-fix..3 %S" func)
            (cl-loop for x = start
                     then (progn
                            (m--debug "m-fix..4 %S %S" func x)
                            (let ((y (funcall func x)))
                              (m--debug "m-fix..5 %S %S %S" func x y)
                              y))
                     until (progn
                             (m--debug "m-fix..6 %S %S" func stopped)
                             (car stopped))
                     do (progn
                          (m--debug "m-fix..7 %S %S" func x)
                          (ts-queue-push output x)
                          (m--debug "m-fix..8 %S %S" func x)
                          ))
            (m--debug "m-fix..9 %S" func)
            (ts-queue-close output)
            (m--debug "m-fix..done %S" func)
            )
        name)
       :stop stopped))))

(defun m-fibonacci ()
  "Return a Fibonacci series machine."
  (let ((prev-prev 0))
    (m-fix #'(lambda (prev)
               (prog1
                   (+ prev prev-prev)
                 (setq prev-prev prev)))
           1)))

(ert-deftest m-fibonacci-test ()
  (message "m-fibonacci-test...")
  (setq ts-queue-debug t)
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
    (m-join m)
    (m--debug "m-fibonacci-test..9")
    )
  ;; (should-be-quiescent)
  (m--debug "m-fibonacci-test..done"))

(defun m-series (left right)
  "Like `m-compose', but RIGHT is not sent input until LEFT is finished.")

(defun m-mapreduce (reduction &rest machines))

(defun m-concat (machines))

(defun m-unfold (func seed))

(defun m-for (machine func)
  "For every output of MACHINE, call FUNC for side-effects."
  (declare (indent 1))
  (cl-loop for x = (m-await machine)
           until (m-eof-p x)
           do (funcall func x)
           finally (m-join machine)))

(ert-deftest m-for-test ()
  (message "m-for-test...")
  (m-for (m-from-list '(1 2 3))
    #'(lambda (x)
        (should (>= x 1))
        (should (<= x 3))))
  ;; (should-be-quiescent)
  (m--debug "m-for-test..done"))

(defun m-map (func machine)
  (m--debug "m-map..1 %S %s" func (machine-name machine))
  (let* ((name (format "m-map %s" (machine-name machine)))
         (output (ts-queue-create :name (concat name " (output)"))))
    (m--debug "m-map..2 %s" name)
    (make-machine
     :name name
     :input (machine-input machine)
     :output output
     :thread
     (make-thread
      #'(lambda ()
          (m--debug "m-map..3 %s" name)
          (m--connect-queues (machine-output machine) output func)
          (m--debug "m-map..4 %s" name)
          (m-join machine)
          (m--debug "m-map..done %s" name)
          )
      name))))

(ert-deftest m-map-test ()
  (message "m-map-test...")
  (let ((m (m-map #'1+ (m-from-list '(1 2 3)))))
    (should (= 2 (m-await m)))
    (should (= 3 (m-await m)))
    (should (= 4 (m-await m)))
    (should (m-output-closed-p m))
    (m-join m))
  ;; (should-be-quiescent)
  (m--debug "m-map-test..done"))

;;; Example machines

(cl-defun m-funcall (func &key (combine #'identity))
  "Turn the function FUNC into a machine.
Since machine might receive their input piece-wise, the caller must
specify a function to COMBINE a list of input into a final input for
FUNC."
  (cl-destructuring-bind (name input output)
      (m--parts "m-funcall")
    (make-machine
     :name name
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
          (ts-queue-close output))
      name))))

(ert-deftest m-funcall-test ()
  (message "m-funcall-test...")
  (let ((m (m-funcall #'+ :combine (apply-partially #'cl-reduce #'+))))
    (m-send m 1)
    (m-send m 2)
    (m-send m 3)
    (m-close-input m)
    (should (= 6 (m-await m)))
    (should (m-output-closed-p m))
    (m-join m))
  ;; (should-be-quiescent)
  (m--debug "m-funcall-test..done"))

(defun m-process (program &rest program-args)
  "Create a machine from a process. See `start-process' for details.
The PROGRAM and PROGRAM-ARGS are used to start the process."
  (m--debug "m-process..1 %S %S" program program-args)
  (cl-destructuring-bind (name input output)
      (m--parts (format "m-process %s" program))
    (m--debug "m-process..2 %s %S %S" name input output)
    (make-machine
     :name name
     :input input
     :output output
     :thread
     (make-thread
      #'(lambda ()
          (m--debug "m-process..3 %s" name)
          (let* (completed
                 (proc
                  (make-process
                   :name "m-process"
                   :command (cons program program-args)
                   :connection-type 'pipe
                   :filter #'(lambda (_proc x)
                               (m--debug "m-process..4 %s %S" name x)
                               (ts-queue-push output x)
                               (m--debug "m-process..5 %s" name)
                               )
                   :sentinel #'(lambda (_proc event)
                                 (m--debug "m-process..6 %s %S" name event)
                                 (ts-queue-close output)
                                 (m--debug "m-process..7 %s" name)
                                 (setq completed t)))))

            (m--debug "m-process..8 %s" name)
            (cl-loop for str = (progn
                                 (m--debug "m-process..9 %s" name)
                                 (let ((x (ts-queue-pop input)))
                                   (m--debug "m-process..10 %s %S" name x)
                                   x))
                     until     (progn
                                 (m--debug "m-process..11 %s %S" name str)
                                 (let ((x (m-eof-p str)))
                                   (m--debug "m-process..12 %s %S" name x)
                                   x))
                     do        (progn
                                 (m--debug "m-process..13 %s %S" name str)
                                 (process-send-string proc str))
                     finally   (progn
                                 (m--debug "m-process..14 %s" name)
                                 (process-send-eof proc)))

            (m--debug "m-process..15 %s" name)
            (while (not completed)
              (m--debug "m-process..16 %s" name)
              (thread-yield)
              (m--debug "m-process..17 %s" name)
              (accept-process-output proc nil 100)
              (m--debug "m-process..18 %s" name)
              )

            (m--debug "m-process..done %s" name)
            ))
      name))))

(ert-deftest m-process-test ()
  (message "m-process-test...")
  (let ((m (m-process "cat")))
    (m-send m "Hello\n")
    (m-close-input m)
    (should (string= "Hello\n" (m-await m)))
    (should (m-output-closed-p m))
    (m-join m))
  ;; (should-be-quiescent)
  (m--debug "m-process-test..done"))

(ert-deftest m-process-drain-test ()
  (message "m-process-drain-test...")
  (let ((m (m-process "echo" "Hello there")))
    (thread-last
      m
      (m-source)
      (m-drain)
      (mapconcat #'identity)
      (string= "Hello there\n")
      should)
    (m-join m))
  ;; (should-be-quiescent)
  (m--debug "m-process-drain-test..done"))

(ert-deftest m-process-compose-test ()
  (message "m-process-compose-test...")
  (setq ts-queue-debug nil)
  (let ((m (m-compose (m-process "grep" "--line-buffered" "foo")
                      (m-process "wc" "-l"))))
    (m-send m "foo\n")
    (m-send m "bar\n")
    (m-send m "foo\n")
    (m-close-input m)
    (should (string= "2\n" (m-await m)))
    (should (m-output-closed-p m))
    (m-join m))
  ;; (should-be-quiescent)
  (m--debug "m-process-compose-test..done"))

(provide 'm)

;;; m.el ends here

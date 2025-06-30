;;; m --- Composible, asynchronous streaming machines -*- lexical-binding: t -*-

;;; Commentary:

;;; Code:

(require 'cl-lib)
(require 'cl-macs)
(require 'ts-queue)
(require 'generator)

(cl-defstruct flag
  "Simple representation of a \"flag\".
It should either be non-nil for active, or nil for inactive."
  name raised)

(defsubst m--debug (&rest args)
  (when ts-queue-debug (apply #'message args))
  (when-let* ((err (thread-last-error t)))
    (message "Thread raised error: %S" err)
    (signal 'thread-killed nil)))

(defun m--drain-queue (stopped input)
  "Drain the INPUT queue and return the list of its values."
  (m--debug "m--drain-queue..1 %S" (ts-queue-name input))
  (cl-loop for x = (ts-queue-pop input)
           until (or (ts-queue-at-eof x)
                     (flag-raised stopped))
           collect x))

(cl-defun m--connect-queues (input output stopped &key func pred)
  "Drain the INPUT queue into the OUTPUT queue."
  (m--debug "m--connect-queues..1 %S %S %S %S"
            (ts-queue-name input)
            (ts-queue-name output)
            func pred)
  (cl-loop for x = (progn
                     (m--debug "m--connect-queues..2")
                     (let ((x (ts-queue-pop input)))
                       (m--debug "m--connect-queues..3 %S" x)
                       x))
           until   (progn
                     (m--debug "m--connect-queues..4 %S %S" x stopped)
                     (or (ts-queue-at-eof x)
                         (flag-raised stopped)))
           do      (progn
                     (m--debug "m--connect-queues..5 %S %S" pred x)
                     (when (or (null pred)
                               (and (not (eq x :ts-queue--eof))
                                    (funcall pred x)))
                       (m--debug "m--connect-queues..6")
                       (ts-queue-push output (funcall (or func #'identity) x)))
                     (m--debug "m--connect-queues..7"))
           finally (progn
                     (m--debug "m--connect-queues..8")
                     (ts-queue-close output)
                     (m--debug "m--connect-queues..9")))
  (m--debug "m--connect-queues..done"))

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
`ts-queue-close'. At this point the thread should exit.

STOP is a function that takes the worker thread and a \"stopped\" flag,
and should take whatever actions are needed to inform the underlying
thread and other resources to cease and clean up. It must always set the
stopped flag once this process has been performed."
  name input output thread resource stop
  (stopped (make-flag :name name)))

(defalias 'm-name #'machine-name)

(defun m-send (machine value)
  "Send the VALUE to the given MACHINE."
  (m--debug "m-send..1 %S %S" (m-name machine) value)
  (ts-queue-push (machine-input machine) value)
  (m--debug "m-send..done %S %S" (m-name machine) value))

(defun m-send-eof (machine)
  "Close the MACHINE's input queue."
  (m--debug "m-send-eof..1 %S" (m-name machine))
  (ts-queue-close (machine-input machine))
  (m--debug "m-send-eof..done %S" (m-name machine)))

(defun m--next-input (machine)
  "Await the next results from the given MACHINE."
  (m--debug "m--next-input..1 %S" (m-name machine))
  (let ((x (ts-queue-pop (machine-input machine))))
    (m--debug "m--next-input..done %S %S" (m-name machine) x)
    x))

(defun m-yield (machine x)
  "Await the next results from the given MACHINE."
  (m--debug "m-yield..1 %S" (m-name machine))
  (ts-queue-push (machine-output machine) x)
  (m--debug "m-yield..done %S" (m-name machine)))

(defun m-yield-eof (machine)
  "Await the next results from the given MACHINE."
  (m--debug "m-yield-eof..1 %S" (m-name machine))
  (ts-queue-close (machine-output machine))
  (m--debug "m-yield-eof..done %S" (m-name machine)))

(defun m-await (machine)
  "Await the next results from the given MACHINE."
  (m--debug "m-await..1 %S" (m-name machine))
  (let ((x (ts-queue-pop (machine-output machine))))
    (m--debug "m-await..done %S %S" (m-name machine) x)
    x))

(defun m-peek (machine)
  "Await the next results from the given MACHINE."
  (m--debug "m-peek..1 %S" (m-name machine))
  (let ((x (ts-queue-peek (machine-output machine))))
    (m--debug "m-peek..done %S %S" (m-name machine) x)
    x))

(defun m--drain-input (machine)
  "Drain the input of MACHINE into a list."
  (m--debug "m--drain-input..1 %S" (m-name machine))
  (let ((xs (m--drain-queue (machine-stopped machine)
                            (machine-input machine))))
    (m--debug "m--drain-input..done %S %S" (m-name machine) xs)
    xs))

(defun m-drain (machine)
  "Drain the output of MACHINE into a list."
  (m--debug "m-drain..1 %S" (m-name machine))
  (let ((xs (m--drain-queue (machine-stopped machine)
                            (machine-output machine))))
    (m--debug "m-drain..done %S %S" (m-name machine) xs)
    xs))

(defun m-stopped-p (machine)
  (let ((x (flag-raised (machine-stopped machine))))
    (m--debug "m-stopped-p %S: %S" (m-name machine) x)
    x))

(defun m-stop (machine)
  "Stop MACHINE, flushing any pending output first."
  (m--debug "m-stop..1 %S" (m-name machine))
  (unless (m-stopped-p machine)
    (m--debug "m-stop..2 %S" (m-name machine))
    (funcall (machine-stop machine) machine))
  (m--debug "m-stop..done %S" (m-name machine)))

(defun m-source (machine)
  "A source is a MACHINE that expects no input."
  (m--debug "m-source..1 %S" (m-name machine))
  (prog1
      machine
    (m--debug "m-source..2 %S" (m-name machine))
    (m-send-eof machine)
    (m--debug "m-source..3 %S" (m-name machine))))

(defun m-sink (machine)
  "A sink is a MACHINE that produces no output."
  (m--debug "m-sink..1 %S" (m-name machine))
  (prog1
      machine
    (m--debug "m-sink..2 %S" (m-name machine))
    (ts-queue-close (machine-output machine))
    (m--debug "m-sink..3 %S" (m-name machine))))

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
  (m--debug "m-output-closed-p..1 %s" (m-name machine))
  (ts-queue-closed-p (machine-output machine)))

(cl-defun m-basic-machine
    (name func &key
          (stop nil)
          (no-input nil)
          (input-size 256)
          (input (unless no-input
                   (ts-queue-create :name (concat name " (input)")
                                    :size input-size)))
          (output-size 256)
          (output (ts-queue-create :name (concat name " (output)")
                                   :size output-size)))
  "Helper macro for creating basic machines.
NAME is the name of the machine.
FUNC is a function taking the constructed machine, and is run inside a
new worker thread for that machine.
STOP is a function that takes the constructed machine and should take
any addition action when a machine stop has been requested.
NO-INPUT should be non-nil if this machine expects no input.
INPUT is the input ts-queue.
INPUT-SIZE is the input queue size, if NO-INPUT and INPUT are is nil.
OUTPUT is the output ts-queue.
OUTPUT-SIZE is the output queue size, if OUTPUT is nil."
  (declare (indent 1))
  (let* ((stopped (make-flag :name name))
         (m (make-machine
             :name name
             :input input
             :output output
             :thread nil
             :resource nil
             :stop nil
             :stopped stopped))
         (thread
          (make-thread #'(lambda ()
                           (m--debug "%s..before" name)
                           (funcall func m)
                           (m--debug "%s..done" name))
                       name)))
    (setf (machine-thread m) thread)
    (setf (machine-stop m)
          #'(lambda (m)
              (unless (flag-raised stopped)
                (m--debug "stop:%s..1" name)
                (when stop
                  (m--debug "stop:%s..2" name)
                  (funcall stop m))
                (m--debug "stop:%s..3" name)

                (m--debug "stop:%s..4" name)
                (setf (flag-raised stopped) t)
                (m--debug "stop:%s..5" name)
                ;; Send an EOF into our own input channel, just in case the
                ;; worker thread is block on a a condition variable awaiting
                ;; an input.
                (when input
                  (m--debug "stop:%s..6" name)
                  (m-send-eof m))
                (m--debug "stop:%s..7" name)
                ;; Drain any output, in case it is blocked waiting to write to
                ;; the outbound queue.
                (when (car (m-peek m))
                  (m--debug "stop:%s..8" name)
                  (m-yield-eof m)
                  (ignore (m-drain m)))
                (m--debug "stop:%s..9" name)
                (when (thread-live-p thread)
                  (m--debug "stop:%s..10" name)
                  (thread-join thread))
                (m--debug "stop:%s..done" name))))
    m))

(defun m-identity ()
  "The identity machine does nothing, just forwards input to output."
  (m-basic-machine "m-identity"
    #'(lambda (m)
        (m--connect-queues (machine-input m) (machine-output m)
                           (machine-stopped m)))))

(defvar m--test-include
  '(
    ;; m-compose-identities
    ;; m-drop
    ;; m-fibonacci
    ;; m-fibonacci-iter
    ;; m-filter
    ;; m-for
    ;; m-from-list
    ;; m-from-list-iter
    ;; m-funcall
    ;; m-generator
    ;; m-head
    ;; m-identity
    ;; m-iterator
    ;; m-map
    ;; m-process
    ;; m-process-compose
    ;; m-process-drain
    ;; m-take
    )
  )

(defmacro m--test (sym &rest body)
  (declare (indent 1))
  (when (or (null m--test-include)
            (memq sym m--test-include))
    (let ((test-name (concat (symbol-name sym) "-test")))
      `(ert-deftest ,(intern test-name) ()
         (message ,(concat test-name "..."))
         (let ((threads (all-threads))
               (procs (process-list)))
           (setq ts-queue-debug ,(not (null m--test-include)))
           (unwind-protect
               ,@body
             (setq ts-queue-debug nil))
           (should (equal threads (all-threads)))
           (should (equal procs (process-list))))
         (m--debug ,(concat test-name "...done"))))))

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

(defun m-compose (left right)
  "Compose the LEFT machine with the RIGHT.
This composes in the reverse order to mathematical composition: the left
machine acts on the inputs coming into the composed machine, and then
passes its outputs to the right machine.

This operation follows monoidal laws with respect to `m-identity',
making this a cartesian closed category of connected streaming machines."
  (let ((name (format "m-compose %s %s"
                      (m-name left) (m-name right))))
    (m-basic-machine name
      #'(lambda (m)
          (cl-loop
           for x = (progn
                     (m--debug "m-compose..3 %S" name)
                     (m-await left))
           until   (progn
                     (m--debug "m-compose..5 %S %S %S"
                               name x (m-stopped-p m))
                     (or (m-eof-p x)
                         (m-stopped-p m)))
           do      (progn
                     (m--debug "m-compose..6 %S" name)
                     (m-send right x)
                     (m--debug "m-compose..7 %S" name))
           finally (progn
                     (m--debug "m-compose..8 %S" name)
                     (m-send-eof right)
                     (m--debug "m-compose..9 %S" name)
                     (m-stop left)
                     (m--debug "m-compose..10 %S" name))))
      :stop #'(lambda (_m)
                (m--debug "m-compose:stop..1 %S" name)
                (m-stop left)
                (m--debug "m-compose:stop..2 %S" name)
                (m-stop right)
                (m--debug "m-compose:stop..3 %S" name))
      :input (machine-input left)
      :output (machine-output right))))

(defalias 'm-connect 'm-compose)
(defalias 'm->> 'm-compose)

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

(defun m-iterator (iter)
  (m-basic-machine "m-iterator"
    #'(lambda (m)
        (let ((output (machine-output m)))
          (m--debug "m-iterator..3 %S" (ts-queue-name output))
          (unwind-protect
              (condition-case e
                  (progn
                    (m--debug "m-iterator..4 %S" (ts-queue-name output))
                    ;; jww (2025-06-28): This drains the iterator eagerly. Instead
                    ;; we would like to use a bounded queue.
                    (cl-loop
                     for x = (progn
                               (m--debug "m-iterator..5 %S" (ts-queue-name output))
                               (prog1
                                   (iter-next iter)
                                 (m--debug "m-iterator..6 %S" (ts-queue-name output)))
                               )
                     until (progn
                             (m--debug "m-iterator..7 %S stopped %S"
                                       (ts-queue-name output) (m-stopped-p m))
                             (m-stopped-p m))
                     do (progn
                          (m--debug "m-iterator..8 %S %S" (ts-queue-name output) x)
                          (ts-queue-push output x)
                          (m--debug "m-iterator..9 %S %S" (ts-queue-name output) x)))
                    (m--debug "m-iterator..10"))
                (iter-end-of-sequence))
            (m--debug "m-iterator..11 %S" (ts-queue-name output))
            (ts-queue-close output)
            (m--debug "m-iterator..12 %S" (ts-queue-name output)))
          (m--debug "m-iterator..done %S" (ts-queue-name output))))
    :no-input t
    :output-size 16))

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

(defun m-from-list-iter (xs)
  (m-iterator
   (funcall (iter-lambda ()
              (dolist (x xs)
                (m--debug "m-from-list..1 %S" x)
                (iter-yield x)
                (m--debug "m-from-list..2 %S" x)
                )
              (m--debug "m-from-list..done")
              ))))

(m--test m-from-list-iter
  (let ((m (m-from-list-iter '(1 2 3 4 5))))
    (should (= 1 (m-await m)))
    (should (= 2 (m-await m)))
    (should (= 3 (m-await m)))
    (should (= 4 (m-await m)))
    (should (= 5 (m-await m)))
    (should (m-output-closed-p m))
    (m-stop m)))

(defun m-from-list (xs)
  (m-basic-machine "m-from-list"
    #'(lambda (m)
        (catch 'done
          (dolist (x xs)
            (m--debug "m-from-list..4 %S" x)
            (if (m-stopped-p m)
                (progn
                  (m--debug "m-from-list..5 %S" x)
                  (throw 'done t))
              (m--debug "m-from-list..6 %S" x)
              (m-yield m x))))
        (m--debug "m-from-list..7")
        (m-yield-eof m))
    :no-input t
    :output-size 1))

(m--test m-from-list
  (let ((m (m-from-list '(1 2 3 4 5))))
    (should (= 1 (m-await m)))
    (should (= 2 (m-await m)))
    (should (= 3 (m-await m)))
    (should (= 4 (m-await m)))
    (should (= 5 (m-await m)))
    (should (m-output-closed-p m))
    (m-stop m)))

(defalias 'm-to-list 'm-drain)

(iter-defun m-generator (machine)
  ;; We cannot use `m-for' here, because it runs afoul of Emacs's detection of
  ;; the use of `iter-yield' inside a generator.
  (cl-loop for x = (m-await machine)
           until (or (m-eof-p x)
                     (m-stopped-p machine))
           do (iter-yield x)
           finally (m-stop machine)))

(m--test m-generator
  (let ((g (m-generator (m-from-list '(1 2 3)))))
    (should (= 1 (iter-next g)))
    (should (= 2 (iter-next g)))
    (should (= 3 (iter-next g)))
    (condition-case x
        (iter-next g)
      (iter-end-of-sequence
       (should (null (cdr x)))))))

(defun m-take (n machine)
  "Take at most N from the given MACHINE.
If MACHINE yields fewer than N elements, this machine yields that same
number of elements."
  (let ((name (format "m-take %s %S" n (m-name machine))))
    (m-basic-machine name
      #'(lambda (m)
          (m--debug "m-take..3 %S" name)
          (cl-loop
           for i from 1 to n
           for x = (progn
                     (m--debug "m-take..4 %S %S %S" name i x)
                     (m-await machine))
           until   (progn
                     (m--debug "m-take..6 %S %S %S" name i x)
                     (or (m-eof-p x)
                         (m-stopped-p m)))
           do      (progn
                     (m--debug "m-take..7 %S %S %S" name i x)
                     (m-yield m x)
                     (m--debug "m-take..8 %S %S %S" name i x))
           finally (progn
                     (m--debug "m-take..9 %S" name)
                     (m-yield-eof m)
                     (m--debug "m-take..10 %S" name)
                     (m-stop machine)
                     (m--debug "m-take..11 %S" name)))
          (m--debug "m-take..done %S" name))
      :stop #'(lambda (_m) (m-stop machine))
      :input (machine-input machine))))

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

(defun m-head (machine)
  (m-take 1 machine))

(m--test m-head
  (let ((m (m-head (m-from-list '(1 2 3 4 5)))))
    (should (= 1 (m-await m)))
    (should (m-output-closed-p m))
    (m-stop m)))

(defun m-drop (n machine)
  "Drop the first N elements from the given MACHINE.
If MACHINE yields fewer than N elements, this machine yields none."
  (let ((name (format "m-drop %s %s" n (m-name machine))))
    (m-basic-machine name
      #'(lambda (m)
          (let (ended)
            (cl-loop for i from 1 to n
                     for x = (m-await machine)
                     until (and (or (m-eof-p x)
                                    (m-stopped-p m))
                                (setq ended t)))
            (m--debug "m-drop..1 %S" name)
            (unless ended
              (cl-loop
               for x = (progn
                         (m--debug "m-drop..2 %S" name)
                         (m-await machine))
               until   (progn
                         (m--debug "m-drop..3 %S %S" name x)
                         (or (m-eof-p x)
                             (m-stopped-p m)))
               do      (progn
                         (m--debug "m-drop..4 %S %S" name x)
                         (m-yield m x)
                         (m--debug "m-drop..5 %S %S" name x))
               finally (progn
                         (m--debug "m-drop..6 %S" name)
                         (m-yield-eof m)
                         (m--debug "m-drop..7 %S" name))))))
      :stop #'(lambda (_m) (m-stop machine))
      :input (machine-input machine))))

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

(iter-defun m--iter-fix (func start)
  "The fixpoint combinator, implemented as an iterator.
Note that this does not stop when f x = x, because Emacs Lisp may yet
have side-effects in the remaining calls. It is up to the caller to
decide whether two of the same answer in a row indicates completion."
  (cl-loop for x = start then (funcall func x)
           ;; until (ts-queue-closed-p input)
           do (iter-yield x)))

(defun m-fix (func start)
  (m-basic-machine "m-fix"
    #'(lambda (m)
        (m--debug "m-fix..1")
        (cl-loop
         for x = start
         then (progn
                (m--debug "m-fix..2 %S" x)
                (let ((y (funcall func x)))
                  (m--debug "m-fix..3 %S %S" x y)
                  y))
         until (progn
                 (m--debug "m-fix..4 %S" (m-stopped-p m))
                 (m-stopped-p m))
         do (progn
              (m--debug "m-fix..5 %S" x)
              (m-yield m x)
              (m--debug "m-fix..6 %S" x)
              ))
        (m--debug "m-fix..7")
        (m-yield-eof m)
        (m--debug "m-fix..done")
        )
    :no-input t
    :output-size 1))

(defun m-fibonacci ()
  "Return a Fibonacci series machine."
  (let ((prev-prev 0))
    (m-fix #'(lambda (prev)
               (prog1
                   (+ prev prev-prev)
                 (setq prev-prev prev)))
           1)))

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

(defun m-fibonacci-iter ()
  "Return a Fibonacci series machine."
  (m-iterator
   (let ((prev-prev 0))
     (m--iter-fix #'(lambda (prev)
                      (prog1
                          (+ prev prev-prev)
                        (setq prev-prev prev)))
                  1))))

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

(defun m-series (left right)
  "Like `m-compose', but RIGHT is not sent input until LEFT is finished.")

(defun m-mapreduce (reduction &rest machines))

(defun m-concat (machines))

(defun m-unfold (func seed))

(defun m-for (machine func)
  "For every output of MACHINE, call FUNC for side-effects."
  (declare (indent 1))
  (cl-loop for x = (m-await machine)
           until   (or (m-eof-p x)
                       (m-stopped-p machine))
           do      (funcall func x)
           finally (m-stop machine)))

(m--test m-for
  (m-for (m-from-list '(1 2 3))
    #'(lambda (x)
        (should (>= x 1))
        (should (<= x 3)))))

(defun m-map (func machine)
  (let ((name (format "m-map %s" (m-name machine))))
    (m-basic-machine name
      #'(lambda (m)
          (m--debug "m-map..1 %S" name)
          (m--connect-queues (machine-output machine) (machine-output m)
                             (machine-stopped m) :func func)
          (m--debug "m-map..2 %S" name)
          (m-stop machine)
          (m--debug "m-map..done %S" name)
          )
      :stop #'(lambda (_m) (m-stop machine))
      :input (machine-input machine))))

(m--test m-map
  (let ((m (m-map #'1+ (m-from-list '(1 2 3)))))
    (should (= 2 (m-await m)))
    (should (= 3 (m-await m)))
    (should (= 4 (m-await m)))
    (should (m-output-closed-p m))
    (m-stop m)))

(defun m-filter (func machine)
  (let ((name (format "m-filter %s" (m-name machine))))
    (m-basic-machine name
      #'(lambda (m)
          (m--debug "m-filter..1 %S" name)
          (m--connect-queues (machine-output machine) (machine-output m)
                             (machine-stopped m) :pred func)
          (m--debug "m-filter..2 %S" name)
          (m-stop machine)
          (m--debug "m-filter..done %S" name)
          )
      :stop #'(lambda (_m) (m-stop machine))
      :input (machine-input machine))))

(m--test m-filter
  (let ((m (m-filter #'cl-evenp (m-from-list '(1 2 3)))))
    (should (= 2 (m-await m)))
    (should (m-output-closed-p m))
    (m-stop m)))

;;; Example machines

(cl-defun m-funcall (func &key (combine #'identity))
  "Turn the function FUNC into a machine.
Since machine might receive their input piece-wise, the caller must
specify a function to COMBINE a list of input into a final input for
FUNC."
  (m-basic-machine "m-funcall"
    #'(lambda (m)
        (thread-last
          (m--drain-input m)
          (funcall combine)
          (funcall func)
          (m-yield m))
        (m-yield-eof m))))

(m--test m-funcall
  (let ((m (m-funcall #'+ :combine (apply-partially #'cl-reduce #'+))))
    (m-send m 1)
    (m-send m 2)
    (m-send m 3)
    (m-send-eof m)
    (should (= 6 (m-await m)))
    (should (m-output-closed-p m))
    (m-stop m)))

(defun m-process (program &rest program-args)
  "Create a machine from a process. See `start-process' for details.
The PROGRAM and PROGRAM-ARGS are used to start the process."
  (let ((name (format "m-process %S" program)))
    (m-basic-machine name
      #'(lambda (m)
          (let* (completed
                 (proc
                  (make-process
                   :name "m-process"
                   :command (cons program program-args)
                   :connection-type 'pipe
                   :filter #'(lambda (_proc x)
                               (m--debug "m-process..1 %S %S" name x)
                               (m-yield m x)
                               (m--debug "m-process..2 %S" name)
                               )
                   :sentinel #'(lambda (_proc event)
                                 (m--debug "m-process..3 %S %S" name event)
                                 (m-yield-eof m)
                                 (m--debug "m-process..4 %S" name)
                                 (setq completed t)))))
            (setf (machine-resource m) proc)

            (m--debug "m-process..5 %S" name)
            (cl-loop
             for str = (progn
                         (m--debug "m-process..6 %S" name)
                         (m--next-input m))
             until     (progn
                         (m--debug "m-process..7 %S %S" name str)
                         (or (not (process-live-p proc))
                             (m-eof-p str)
                             (m-stopped-p m)))
             do        (progn
                         (m--debug "m-process..8 %S %S" name str)
                         (process-send-string proc str))
             finally   (progn
                         (m--debug "m-process..9 %S" name)
                         (process-send-eof proc)))

            (m--debug "m-process..10 %S" name)
            (while (and (not completed)
                        (process-live-p proc)
                        (not (m-stopped-p m)))
              (m--debug "m-process..11 %S" name)
              (thread-yield)
              (m--debug "m-process..12 %S" name)
              (accept-process-output proc nil 100)
              (m--debug "m-process..13 %S" name)))))))

(m--test m-process
  (let ((m (m-process "cat")))
    (m-send m "Hello\n")
    (m-send-eof m)
    (should (string= "Hello\n" (m-await m)))
    (should (m-output-closed-p m))
    (m-stop m)))

(m--test m-process-drain
  (let ((m (m-process "echo" "Hello there")))
    (thread-last
      (m-source m)
      (m-drain)
      (mapconcat #'identity)
      (string= "Hello there\n")
      should)
    (m-stop m)))

(m--test m-process-compose
  (let ((m (m-compose (m-process "grep" "--line-buffered" "foo")
                      (m-process "wc" "-l"))))
    (m-send m "foo\n")
    (m-send m "bar\n")
    (m-send m "foo\n")
    (m-send-eof m)
    (should (string= "2\n" (m-await m)))
    (should (m-output-closed-p m))
    (m-stop m)))

(provide 'm)

;;; m.el ends here

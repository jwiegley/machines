;;; actor.el --- Actor model in Emacs Lisp, using EIEIO -*- lexical-binding: t -*-

;;; Commentary:

;; This code is taken from
;; https://github.com/naveensundarg/Common-Lisp-Actors/blob/master/actors.lisp
;; or
;; https://github.com/DruidGreeneyes/cl-actors/blob/master/actors.lisp

;;; Code:

(require 'cl-lib)
(require 'eieio)
(require 'ts-queue)

;; ----------------------------------------------------------------------------
(defclass actor()
  ((name :initarg :name
         :initform (error ":name must be specified")
         :accessor name
         :documentation "Hold the name of actor")
   (behavior :initarg :behavior
             :initform (error ":behav must be specified")
             :accessor behavior
             :documentation "Behavior")
   (messages :initform '()
             :accessor messages
             :documentation "Message stream sent to actor")
   thread))

;; ----------------------------------------------------------------------------
(cl-defmethod initialize-instance :after ((self actor) &optional slots)
  "Uses the main functiona name to create a thread."
  (message "initialize-instance..1")
  (with-slots (name thread messages) self
    (setf messages (ts-queue-create))
    (setf thread (make-thread #'(lambda() (main self)) name))))

(cl-defmethod send ((self actor) &rest message)
  "Creates a message sending thread which
1. Holds lock to the message (queue)
2. Appends messages (queue) with incoming message
3. Releases lock
4. Notifies the waiting thread that there is a message"
  (message "send..1 %S" message)
  (with-slots (messages) self
    (make-thread #'(lambda ()
                     (message "send:thread..1")
                     (ts-queue-push messages message)))
    (cl-values)))

(cl-defmethod close-actor ((self actor))
  (message "close-actor..1")
  (with-slots (messages) self
    (make-thread #'(lambda ()
                     (message "close-actor:thread..1")
                     (ts-queue-close messages)))
    (cl-values)))

(cl-defmethod cancel-actor ((self actor))
  "Cancels the actor thread, stopping it immediately with a signal."
  (message "cancel-actor..1")
  (with-slots (thread) self
    (thread-signal thread 'canceled nil)))

(cl-defmethod stop-actor ((self actor))
  "Stops the actor thread by sending it a closed input signal."
  (message "stop-actor..1")
  (close-actor self)
  (with-slots (thread) self
    (thread-join thread)))

(cl-defmethod get-thread ((self actor))
  "Returns the handle of a thread"
  (message "get-thread..1")
  (with-slots (thread) self thread))

;; ----------------------------------------------------------------------------
(cl-defmethod main ((self actor))
  "The main which is started as a thread from the constructor I think that
this should be more of an internal function than a method (experiment
with funcallable-standard-class)."
  (message "main..1")
  (with-slots ((behav behavior) messages) self
    (cl-loop while behav
             for x = (progn (message "main:loop..1")
                            (thread-yield)
                            (ts-queue-pop messages))
             until (ts-queue-at-eof x)
             do (setf behav (apply behav x)))))

(defmacro behav (state vars &body body)
  "Create a behavior that can be attached to any actor."
  (message "behav..1")
  `(let ,state
     (cl-labels ((me ,(append vars `(&key self  (next #'me next-supplied-p)))
                   (setf next (curry next :self self))
                   x   ,@body))
       #'me)))

(cl-defmacro defactor (name state vars &body body)
  "Macro for creating actors with the behavior specified by body."
  (declare (indent 3))
  `(cl-defun ,name (&key (self) ,@state)
     (cl-labels ((me ,(append vars `(&key (next #'me next-supplied-p)))
                   (if next-supplied-p
                       (setf next (curry next :self self)))
                   ,@body))
       (setf self (make-actor #'me ,(symbol-name name))) self)))

(defun make-actor (behav name)
  (message "make-actor..1")
  (make-instance 'actor
                 :name (cl-concatenate 'string "Actor: " name)
                 :behavior behav))

(defun if-single (x)
  (if (eq (length x) 1)
      (car x)
    x))

(defun sink (&rest _args)
  #'sink)

(defun curry (f &rest args)
  #'(lambda (&rest rem) (apply f (append rem args))))

(defactor printer () (x)
  (message "printer: %S" x)
  next)

(defun actor-test ()
  (let ((my-actor (printer)))
    (thread-yield)
    (message "%S" (thread-last-error t))
    (send my-actor 1)
    (thread-yield)
    (message "%S" (thread-last-error t))
    (send my-actor 2)
    (thread-yield)
    (message "%S" (thread-last-error t))
    (send my-actor 3)
    (thread-yield)
    (message "%S" (thread-last-error t))
    (let ((result (stop-actor my-actor)))
      (message "Actor stopped: %S" result)
      result)))

(defun run-actor ()
  (interactive)
  (let ((thread (make-thread #'(lambda () (actor-test))))
        (countdown 3000))
    (while (and (thread-live-p thread)
                (> 0 (setq countdown (1- countdown))))
      (thread-yield)
      (sit-for 0.01))))

(provide 'actor)

;;; actor.el ends here

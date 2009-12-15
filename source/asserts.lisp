;;; -*- mode: Lisp; Syntax: Common-Lisp; -*-
;;;
;;; Copyright (c) 2006 by the authors.
;;;
;;; See LICENCE for details.

(in-package :hu.dwim.stefil)

(defun extract-assert-expression-and-message (input-form)
  (bind ((negatedp nil)
         (predicate)
         (arguments '()))
    (labels ((process (form)
               (if (consp form)
                   (case (first form)
                     ((not)
                      (assert (= (length form) 2))
                      (setf negatedp (not negatedp))
                      (process (second form)))
                     (t (setf predicate (first form))
                        (setf arguments (rest form))))
                   (setf predicate form))))
      (process input-form)
      (cond ((ignore-errors
               (macro-function predicate))
             (values '() input-form "Macro expression ~S evaluated to false." (list `(quote ,input-form))))
            ((and (ignore-errors
                    (fdefinition predicate))
                  ;; let's just skip CL:IF and don't change its evaluation semantics while trying to be more informative...
                  (not (eq predicate 'if)))
             (cond ((= (length arguments) 0)
                    (values '()
                            input-form
                            "Expression ~A evaluated to false."
                            (list `(quote ,input-form))))
                   ((= (length arguments) 2)
                    (with-unique-names (x y)
                      (values `((,x ,(first arguments))
                                (,y ,(second arguments)))
                              (if negatedp
                                  `(not (,predicate ,x ,y))
                                  `(,predicate ,x ,y))
                              "Binary predicate ~A failed.~%~
                               x: ~S => ~S~%~
                               y: ~S => ~S"
                              (list (if negatedp
                                        `(quote (not (,predicate x y)))
                                        `(quote (,predicate x y)))
                                    `(quote ,(first arguments)) x
                                    `(quote ,(second arguments)) y))))
                   (t (bind ((arg-values (mapcar (lambda (el)
                                                   (unless (keywordp el)
                                                     (gensym)))
                                                 arguments))
                             (bindings (loop
                                         :for arg :in arguments
                                         :for arg-value :in arg-values
                                         :when arg-value
                                           :collect `(,arg-value ,arg)))
                             (expression-values (mapcar (lambda (arg-value argument)
                                                          (or arg-value argument))
                                                        arg-values
                                                        arguments))
                             (expression (if negatedp
                                             `(not (,predicate ,@expression-values))
                                             `(,predicate ,@expression-values)))
                             ((:values message message-args) (loop
                                                               :with message = "Expression ~A evaluated to ~A"
                                                               :for arg :in arguments
                                                               :for idx :upfrom 0
                                                               :for arg-value :in arg-values
                                                               :when arg-value
                                                                 :do (setf message (concatenate 'string message "~%~D: ~A => ~S"))
                                                                 :and :appending `(,idx (quote ,arg) ,arg-value) :into message-args
                                                               :finally (return (values message message-args)))))
                        (values bindings
                                expression
                                message
                                (nconc (list `(quote (,predicate ,@arguments)) (if negatedp "true" "false")) message-args))))))
            (t
             (values '() input-form "Expression ~A evaluated to false." (list `(quote ,input-form))))))))

(defun write-progress-char (char)
  (bind ((global-context (when (boundp '*global-context*)
                           *global-context*)))
    (when (and global-context
               (print-test-run-progress-p global-context))
      (when (and (not (zerop (progress-char-count-of global-context)))
                 (zerop (mod (progress-char-count-of global-context)
                             *test-progress-print-right-margin*)))
        (terpri *debug-io*))
      (incf (progress-char-count-of global-context)))
    (when (or (and global-context
                   (print-test-run-progress-p global-context))
              (and (not global-context)
                   *print-test-run-progress*))
      (write-char char *debug-io*))))

(defun register-assertion-was-successful ()
  (write-progress-char #\.))

(defun register-assertion ()
  (when (boundp '*global-context*)
    (incf (assertion-count-of *global-context*))))

(defun record-unexpected-error (condition)
  (assert (not (typep condition 'assertion-failed)))
  (record-failure* 'unexpected-error
                   :description-initargs (list :condition condition)
                   :signal-assertion-failed nil)
  (when (or (debug-on-unexpected-error-p *global-context*)
            #+sbcl(typep condition 'sb-kernel::control-stack-exhausted))
    (invoke-debugger condition))
  (values))

(defun record-failure (failure-description-type &rest args)
  (record-failure* failure-description-type :description-initargs args))

(defun record-failure* (failure-description-type &key (signal-assertion-failed t) description-initargs)
  (bind ((description (apply #'make-instance failure-description-type
                             :test-context-backtrace (when (has-context)
                                                       (loop
                                                         :for context = (current-context) :then (parent-context-of context)
                                                         :while context
                                                         :collect context))
                             description-initargs)))
    (if (and (has-global-context)
             (has-context))
        (progn
          (vector-push-extend description (failure-descriptions-of *global-context*))
          (incf (number-of-added-failure-descriptions-of *context*))
          (write-progress-char (progress-char-of description))
          (when signal-assertion-failed
            (restart-case
                (error 'assertion-failed
                       :test (test-of *context*)
                       :failure-description description)
              (continue ()
                :report (lambda (stream)
                          (format stream "~@<Roger, go on testing...~@:>"))))))
        (progn
          (describe description *debug-io*)
          (when *debug-on-assertion-failure* ; we have no *global-context*
            (restart-case (error 'assertion-failed
                                 :failure-description description)
              (continue ()
                :report (lambda (stream)
                          (format stream "~@<Ignore the failure and continue~@:>")))))))))

(defmacro is (&whole whole form &optional (message nil message-p) &rest message-args)
  (bind (((:values bindings expression message message-args)
          (if message-p
              (values nil form message message-args)
              (extract-assert-expression-and-message form))))
    (with-unique-names (result)
      `(progn
        (register-assertion)
        (bind ,bindings
          (bind ((,result (multiple-value-list ,expression)))
            (if (first ,result)
                (register-assertion-was-successful)
                (record-failure 'failed-assertion :form ',whole
                                :format-control ,message :format-arguments (list ,@message-args)))
            (values-list ,result)))))))

(defmacro signals (&whole whole what &body body)
  (bind ((condition-type what))
    (unless (symbolp condition-type)
      (error "SIGNALS expects a symbol as condition-type! (Is there a superfulous quote at ~S?)" condition-type))
    `(progn
      (register-assertion)
      (block test-block
        (handler-bind ((,condition-type
                        (lambda (c)
                          (register-assertion-was-successful)
                          (return-from test-block c))))
          ,@body)
        (record-failure 'missing-condition
                        :form ',whole
                        :condition ',condition-type)
        (values)))))

(defmacro not-signals (&whole whole what &body body)
  (bind ((condition-type what))
    (unless (symbolp condition-type)
      (error "SIGNALS expects a symbol as condition-type! (Is there a superfulous quote at ~S?)" condition-type))
    `(progn
       (register-assertion)
       (block test-block
         (multiple-value-prog1
             (handler-bind ((,condition-type
                             (lambda (c)
                               (record-failure 'extra-condition
                                               :form ',whole
                                               :condition c)
                               (return-from test-block c))))
               ,@body)
           (register-assertion-was-successful))))))

(defmacro finishes (&whole whole_ &body body)
  ;; could be `(not-signals t ,@body), but that would register a confusing failed-assertion
  (with-unique-names (success? whole)
    `(bind ((,success? nil)
            (,whole ',whole_))
       (register-assertion)
       (unwind-protect
            (multiple-value-prog1
                (progn
                  ,@body)
              (setf ,success? t)
              (register-assertion-was-successful))
         (unless ,success?
           (record-failure 'failed-assertion
                           :form ,whole
                           :format-control "FINISHES block did not finish: ~S"
                           :format-arguments ,whole))))))
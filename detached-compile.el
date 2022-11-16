;;; detached-compile.el --- Detached integration for compile -*- lexical-binding: t -*-

;; Copyright (C) 2022  Free Software Foundation, Inc.

;; This file is part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This is a `detached' extension which provides integration for `compile'.

;;; Code:

;;;; Requirements

(require 'compile)
(require 'detached)

(declare-function ansi-color-compilation-filter "ansi-color")

;;;; Variables

(defcustom detached-compile-session-action
  '(:attach detached-compile-attach
			:view detached-compile-session
			:run detached-compile)
  "Actions for a session created with `detached-compile'."
  :group 'detached
  :type 'plist)

;;;; Commands

;;;###autoload
(defun detached-compile (command &optional comint)
  "Run COMMAND through `compile' but in a 'detached' session.
Optionally enable COMINT if prefix-argument is provided."
  (interactive
   (list
	(let ((command (eval compile-command t)))
	  (if (or compilation-read-command current-prefix-arg)
		  (compilation-read-command command)
		command))
	(consp current-prefix-arg)))
  (let* ((detached-enabled t)
		 (detached-session-origin (or detached-session-origin 'compile))
		 (detached-session-action (or detached-session-action
									  detached-compile-session-action))
		 (detached-session-mode (or detached-session-mode 'attached))
		 (detached-current-session (detached-create-session command)))
	(compile command comint)))

;;;###autoload
(defun detached-compile-recompile (&optional edit-command)
  "Re-compile by running `compile' but in a 'detached' session.
Optionally EDIT-COMMAND."
  (interactive "P")
  (let* ((detached-enabled t)
		 (detached-session-action detached-compile-session-action)
		 (detached-session-origin 'compile)
		 (detached-session-mode 'attached)
		 (detached-current-session edit-command))
	(recompile edit-command)))

(defun detached-compile-kill ()
  "Kill a 'detached' session."
  (interactive)
  (detached-kill-session detached-buffer-session))

;;;;; Functions

;;;###autoload
(defun detached-compile-attach (session)
  "Attach to SESSION with `compile'."
  (when (detached-valid-session session)
    (let* ((detached-enabled t)
           (detached-current-session session)
           (detached-local-session (detached-session-local-p session))
           (default-directory (detached-session-directory session)))
      (compilation-start (detached-session-command session)))))

;;;;; Support functions

;;;###autoload
(defun detached-compile--start (_)
  "Run in `compilation-start-hook' if `detached-enabled'."
  (when detached-enabled
    (setq-local default-directory (detached-session-working-directory detached-current-session))
    (setq detached-buffer-session detached-current-session)
    (setq compile-command (detached-session-command detached-current-session))
    (setq compilation-arguments nil)
    (detached-compile--replace-modesetter)
    (when detached-filter-ansi-sequences
      (add-hook 'compilation-filter-hook #'ansi-color-compilation-filter 0 t))
    (add-hook 'comint-preoutput-filter-functions #'detached--env-message-filter 0 t)
    (add-hook 'comint-preoutput-filter-functions #'detached--dtach-eof-message-filter 0 t)))

(defun detached-compile--compilation-start (compilation-start &rest args)
  "Create a `detached' session before running COMPILATION-START with ARGS."
  (if detached-enabled
	  (pcase-let ((`(,_command ,mode ,name-function ,highlight-regexp) args))
		(if (eq detached-session-mode 'detached)
			(detached-start-detached-session detached-current-session)
		  (apply compilation-start `(,(if (detached-session-started-p detached-current-session)
                                          (detached-session-attach-command detached-current-session
                                                                           :type 'string)
                                        (detached-session-start-command detached-current-session
                                                                        :type 'string))
									 ,(or mode 'detached-compilation-mode)
									 ,name-function
									 ,highlight-regexp))))
	(apply compilation-start args)))

(defun detached-compile--replace-modesetter ()
  "Replace the modsetter inserted by `compilation-start'."
  (save-excursion
	(let ((inhibit-read-only t)
		  (regexp (rx (regexp "^dtach ") (or "-c" "-a") (regexp ".*\.socket.*$"))))
	  (goto-char (point-min))
	  (when (re-search-forward regexp nil t)
		(delete-region (match-beginning 0) (match-end 0))
		(insert (detached-session-command detached-current-session))))))

(defun detached-compile--compilation-detached-filter ()
  "Filter to modify the output in a compilation buffer."
  (let ((begin compilation-filter-start)
		(end (copy-marker (point))))
	(save-excursion
	  (goto-char begin)
	  (when (re-search-forward "\n?Detached session.*\n?" end t)
		(delete-region (match-beginning 0) (match-end 0))))))

(defun detached-compile--compilation-eof-filter ()
  "Filter to modify the output in a compilation buffer."
  (let ((begin compilation-filter-start)
		(end (copy-marker (point))))
	(save-excursion
	  (goto-char begin)
	  (when (re-search-forward (format "\n?%s\n" detached--dtach-eof-message) end t)
		(delete-region (match-beginning 0) (match-end 0))))))

(cl-defmethod detached--detach-session ((_mode (derived-mode detached-compilation-mode)))
  "Detach from session when MODE is `detached-compilation-mode'."
  (detached--detach-from-comint-process)
  (detached--quit-session-buffer))

;;;;; Major modes

(defvar detached-compilation-mode-map
  (let ((map (make-sparse-keymap)))
	(define-key map (kbd "C-c C-k") #'detached-compile-kill)
	(define-key map (kbd "C-c C-.") #'detached-describe-session)
	(define-key map (kbd detached-detach-key) #'detached-detach-session)
	map)
  "Keymap for `detached-compilation-mode'.")

;;;###autoload
(define-derived-mode detached-compilation-mode compilation-mode "Detached Compilation"
  "Major mode for `detached' compilation."
  (add-hook 'compilation-filter-hook #'detached-compile--compilation-eof-filter 0 t)
  (add-hook 'compilation-filter-hook #'detached-compile--compilation-detached-filter 0 t))

(advice-add #'compilation-start :around #'detached-compile--compilation-start)

(provide 'detached-compile)

;;; detached-compile.el ends here

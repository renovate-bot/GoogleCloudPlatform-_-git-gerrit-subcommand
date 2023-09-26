;; Copyright 2023 Google LLC
;; Author: Jun Sheng
;;
;; Licensed under the Apache License, Version 2.0 (the "License");
;; you may not use this file except in compliance with the License.
;; You may obtain a copy of the License at
;;
;;     https://www.apache.org/licenses/LICENSE-2.0
;;
;; Unless required by applicable law or agreed to in writing, software
;; distributed under the License is distributed on an "AS IS" BASIS,
;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;; See the License for the specific language governing permissions and
;; limitations under the License.

#lang racket

(define VERSION "0.1-preview")
(require "scsh/scsh-repf.rkt")

(require "alvs/and-let-values.rkt")

(define sub-commands (make-hash))
(define version-cmd
  (lambda a
    (let ([os (system-type 'os*)]
	  [arch (system-type 'arch)]
	  [vm (system-type 'vm)])
      (display (format
		"git-gerrit ~a.\n" VERSION))
      (display (format "Runtime: racket(~a) ~a, ~a, ~a.\n"
		       vm
		       (version)
		       arch os)))))
(hash-set! sub-commands "version" version-cmd)

(define gerrit-dir (make-parameter "GERRIT"))
(define gerrit-remote (make-parameter "origin"))
(define top-level (make-parameter #f))
(define upload-prefix (make-parameter "refs/for"))

(define (gerrit-config-name*  ws cfg)
  (format "gerrit.~a~a" ws (if cfg (format ".~a" cfg)
			       "")))

(define-syntax gerrit-config-name
  (syntax-rules ()
    ((_ ws cfg)
     (let ((ws-str (stringify `ws))
	   (cfg-str (stringify `cfg)))
       (gerrit-config-name* ws-str cfg-str)))
    ((_ ws)
     (let ((ws-str (stringify `ws)))
       (gerrit-config-name* ws-str #f)))))

(define (check-not-submitted base-branch change-id)
  (and-let*-tag-values-check
   ([(0 _) 'config-null
     (if (and base-branch change-id)
	 (values 0 #t)
	 (values 1 #f))]
    [(0 _) 'found-in-base
     (check-changeid-not-in-target change-id base-branch)])
   (values 0 #t)
   (else (lambda (t)
	   (let ([reason
		  (match t
		    ['config "Can't get config, not in a gerrit workspace."]
		    ['config-null "Config gerrit.base-branch or gerrit.change-id is null."]
		    ['found-in-base "Looks workspace has been submitted."]
		    [else "Unknown error."])])
	     (begin
	       (display (format "~a\n" reason)
			(current-error-port))
	       (values 1 #f)))))))

(define (get-ws-config)
  (and-let*-tag-values-check
   ([(0 ws-name) 'gerrit-ws-name
     (run/status+car-strings (git branch --show-current "--format=%(refname:short)"))]
    [(0 temp-top-level) 'get-top-level
     (run/status+strings-suppress-error
      (git rev-parse --show-toplevel))]
    [(0) 'check-same-wsname-branch
     (if (equal? ws-name
		 (let-values
		     ([(_ t __) (split-path
				 (string->path (car temp-top-level)))])
		   (path->string t)))
	 (values 0)
	 (begin
	   (display (format "mismatch ~a ~a\n" ws-name (car temp-top-level))
		    (current-error-port))
	   (values 1)))]
    [(0 staged) 'workspace-not-clean
     (run/status+strings
      (git status --untracked-files=no --porcelain))]
    [('ok) 'workspace-not-clean2
     (if (pair? staged)
	 'err
	 'ok)]
    [(0 base-branch) 'gerrit.base-branch
     (run/status+car-strings
      (git config --get ,(gerrit-config-name ,ws-name base-branch)))]
    [(0 related-to) 'gerrit.related-to
     (run/status+car-strings
      (git config --get ,(gerrit-config-name ,ws-name related-to)))]
    [(0 change-id) 'gerrit.changeid
     (run/status+car-strings
      (git config --get ,(gerrit-config-name ,ws-name change-id)))]
    [(0 last-upload) 'gerrit.last-upload
     (run/status+car-strings
      (git config --get --default 0 ,(gerrit-config-name ,ws-name last-upload)))])
   (let-values
       ([(code not-submitted)
	 (check-not-submitted base-branch change-id)])
     (values ws-name base-branch related-to change-id last-upload not-submitted))
   (else
    (lambda (t)
      (let ([reason
	     (match t
	       [(or 'workspace-not-clean 'workspace-not-clean2)
		(format "Workspace \"~a\" not clean, consider commit or stash the changes" ws-name)]
	       [_ (format "Misc error when getting config: ~a" t)])])
	(display (format "~a\n" reason )
		 (current-error-port)))
      (exit 1)))))

(define (get-status)
  (let-values ([(ws-name base-branch related-to change-id last-upload not-submitted) (get-ws-config)])
    (and-let*-tag-values-check
     ([(0) 'submitted
       (if not-submitted 0 1)]
      [(0 top-commit) 'get-head
       (run/status+car-strings
	(git log -n 1 "--format=%H" ,ws-name "--"))]
      [(0 temp-need-upload) 'get-needupload
       (if (equal? top-commit last-upload)
	   (values 0 #f)
	   (values 0 top-commit))]
      [(0 max-ref) 'find-max-ref
       (if (equal? related-to "0")
	   (values 0 base-branch)
	   (find-change-max related-to))]
      [(0 temp-max-ref-commit) 'find-max-ref-commit
       (if (check-empty-base-branch max-ref)
	   (values 0 #f)
	   (run/status+car-strings
	    (git log -n 1 "--format=%H" ,max-ref "--")))]
      [(0 related-base-merged) 'find-related-base-merged
       (let-values ([(status ref)
		     (if temp-max-ref-commit
			 (run/status+car-strings
			  (git merge-base --is-ancestor ,temp-max-ref-commit ,base-branch))
			 (values 0 #f))])
	 (if (eq? status 0)
	     (values 0 #t)
	     (values 0 #f)))]
      [(0 max-ref-commit) 'find-real-max-ref-commit
       (if related-base-merged
	   (run/status+car-strings
	    (git log -n 1 "--format=%H" ,base-branch "--"))
	   (values 0 temp-max-ref-commit))]
      [(0 fork-point) 'get-forkpoint
       (find-merge-point ws-name base-branch
			 (if related-base-merged "0" related-to) )]
      [(0 fork-commit) 'get-forkpoint-commit
       (if fork-point
	   (run/status+car-strings
	    (git log -n 1 "--format=%H" ,fork-point "--"))
	   (values 0 #f))]
      [(0 need-upload) 'get-real-need-upload
       (if (and temp-need-upload 
		(equal? temp-need-upload fork-commit))
	   (values 0 #f)
	   (values 0 temp-need-upload))]
      
      [(0 rebase-suggestion rebase-from) 'find-rebase-suggestion
       (if (or related-base-merged
	       (equal? related-to "0"))
	   (values 0
		   (if (equal? fork-commit max-ref-commit)
		       #f
		       base-branch)
		   base-branch)
	   (values 0
		   (if (equal? fork-commit max-ref-commit)
		       #f
		       max-ref)
		   fork-point))])
     (values ws-name need-upload rebase-suggestion rebase-from (if related-base-merged "0" related-to) change-id base-branch fork-point)
     (else (lambda (t)
	     (match t
	       ['submitted (display (format "Workspace \"~a\" has already been submitted.\n" ws-name)
				    (current-error-port))]
	       [_ (display (format "Error in get-status at ~a.\n" t)
			   (current-error-port))])
	     (exit 1))))))


(define (get-a-new-message-commit base-branch changeid)
  (let ((tmp-file (make-temporary-file "git-gerrit~a")))
    (dynamic-wind
      (lambda () #t)
      (lambda ()
	(with-output-to-file tmp-file
	  (lambda ()
	    (begin
	      (display "## Input your commit message for submission\n\n")
	      (display "## Commit history since start-workspace:\n")
	      (let-values ([(status outs)
			    (if base-branch
				(run/status+strings
				 (git log "--format=# %s" ,(format "~a.." base-branch) "--"))
				(run/status+strings
				 (git log "--format=# %s")))])
		(if (eq? status 0)
		    (display (string-join outs "\n"))
		    (begin
		      (display "Error on getting history\n"
			       (current-error-port))
		      (exit 1))))
	      (display "\n\n")
	      (display "## Don't change lines below, including the empty line:\n\n")
	      (display (format "Change-Id: ~a\n" changeid))))
	  #:exists 'truncate)
	(if (eq? 0 (run (git commit -t ,(path->string tmp-file) --allow-empty)))
	    #t
	    (begin (display "Abort.\n" (current-error-port))
		   (exit 1))))
      (lambda ()
	(delete-file tmp-file)))))

(define (squash-and-upload ws message-commit start-ref base-branch need-upload)
  (and-let*-tag-values-check
   ([('ok top-commit) 'uploaded
     (if need-upload
	 (values 'ok need-upload )
	 (values 'fail need-upload ))]
    [('ok upload-branch) 'never-reached
     (values 'ok (format "~a.~a" ws top-commit))]
    [(0 _) 'new-branch
     (if start-ref
	 (run/status+strings (git checkout -b ,upload-branch))
	 (run/status+strings (git checkout ,(format "--orphan=~a" upload-branch)) ))]
    [(0 _) 'squash
     (if start-ref
	 (run/status+strings (git reset --soft ,start-ref))
	 (values 0 #t ;do nothing
		 ))]
    [(0) 'commit
     (run (git commit -C ,message-commit))]
    [(0) 'upload
     (let ([s1 (run (git -c remote.origin.mirror=false push ,(gerrit-remote)
		      ,(format "~a:~a/~a" upload-branch (upload-prefix) base-branch)))])
       (run (git checkout ,ws))
       (run (git branch -D ,upload-branch))
       s1)]
    [(0 _) 'update-config
     (run/status+strings
      (git config --add ,(gerrit-config-name ,ws last-upload) ,top-commit))])
   0
   (else
    (lambda (t)
      (let ([reason (match t
		      ['top-commit "Can't find recent commit"]
		      ['uploaded  "Seems current workspace has been uploaded"]
		      [_ "Misc Errors"])])
	(display (format "~a: tag: ~a\n" reason t)
		 (current-error-port))
	1)))))

(define (call/top-level ws-tree top-lvl thunk)
  (match `(,ws-tree ,top-lvl)
    [(list (and w (not #f)) #f)
     (begin
       (gerrit-dir (path->string (path->complete-path (gerrit-dir))))
       (with-cwd
	w
	(call/top-level #f (current-directory) thunk)))]
    [(list #f (and tpl (not #f)))
     (thunk)]
    [else (display (format "Invalid workspace.\n")
		   (current-error-port))
	  1]))

(define (upload-change ws)
  (call/top-level
   ws (top-level)
   (lambda ()
     (let go-with-message-commit ((message-commit #f))
       (let-values
	   ([(ws-name need-upload
		      rebase-suggestion
		      rebase-from related-to
		      changeid
		      base-branch start-ref)
	     (get-status)])
	(if (not message-commit)
	    (let-values ([(status out)
			  (run/status+strings
			   (git log -n 1 "--format=%H" --grep ,(format "^Change-Id: ~a$" changeid)))])
	      (if (and (eq? status 0) (pair? out))
		  (go-with-message-commit (car out))
		  (begin (get-a-new-message-commit start-ref changeid)
			 (go-with-message-commit #f))))
	    (squash-and-upload ws-name message-commit start-ref base-branch need-upload)))))))

(define (find-merge-point ws base-branch related-to)
  (if (equal? related-to "0")
      (if (check-empty-base-branch base-branch)
	  (values 0 #f)
	  (let-values ([(status outs)
			(run/status+strings
			 (git merge-base ,ws ,base-branch))])
	    (if (pair? outs)
		(values 0 (car outs))
		(values 0 #f))))
      (let lp
	  ([refs
	    (let-values ([(status r)
			  (run/status+strings
			   (git 
			    for-each-ref "--format=%(refname)"
			    ,(format "refs/changes/*/~a/*"
				     related-to)))])
	      r)])
	(if (not (pair? refs))
	    (values 1 #f)
	    (let ((ref (car refs)))
	      (let-values ([(status _)
			    (run/status+car-strings
			     (git merge-base --is-ancestor ,ref ,ws))])
		(if (eq? status 0)
		    (values 0 ref)
		    (lp (cdr refs)))))))))

(define (check-empty-base-branch branch)
  (let-values
      ([(status _) (run/status+strings-suppress-error
		    (git --git-dir ,(gerrit-dir)
			 rev-list -n 1 ,branch --))])
    (not (eq? status 0))))


(define (check-changeid-not-in-target changeid target)
  (if (check-empty-base-branch target)
      (values 0 changeid)
      (let-values ([(status out)
		    (run/status+strings
		     (git log --oneline
			  --grep ,(format "^Change-Id: ~a$" changeid)
			  ,target))])
	(if (eq? status 0)
	    (if (pair? out)
		(values 1 #f)
		(values 0 changeid))
	    (values 1 #f)))))

(define (start-workspace ws-name base-branch relate-to-change resume-from-change)
  " ws-name: the name of workspace, should be a valid directory name
    base-branch: the target branch which the changes are uploaded for
    relate-to-change: the change number which all work will be based on
    resume-from-change: the change-num from which all work will be resumed 
    
    worktree config: base-branch, related-to, change-id
    base-branch: default branch or specify
    related-to: the change num based on, 0 for non-related-change
    change-id: if resume-from-change, the changeid from change-num, otherwise a new hash
    "
  (with-cwd
   (let-values ([(t _ __) (split-path (gerrit-dir))])
     (match t
       ['relative "."]
       [(and p (? path? p)) p]))
   (and-let*-tag-values-check
    ([(0 _) 'check-exclusive
      (if (and relate-to-change resume-from-change)
	  (values 1 #f)
	  (values 0 #t))]
     [(0 base-branch-real) 'get-base-branch
      (if base-branch
	  (values 0 base-branch)
	  (run/status+car-strings (git --git-dir ,(gerrit-dir)
				       symbolic-ref --short HEAD)))]
     [(0 change-id-hash) 'gen-change-id-hash
      (run/status+car-strings (git hash-object --stdin)
			      (<< (format "~a ~a"
					  ws-name
					  (current-inexact-milliseconds))))]
     [(0 checkout-head) 'find-checkout-head
      (if relate-to-change
	  (find-change-max relate-to-change)
	  (if resume-from-change
	      (find-change-max resume-from-change)
	      (values 0 base-branch-real)))]
    
     [(0 last-uploaded real-change-id) 'cant-resume
      (if resume-from-change
	  (and-let*-tag-values-check
	   ([(0 trailer-changeid) 'checkout-trailer
	     (run/status+car-strings
	      (git --git-dir ,(gerrit-dir)
		   log -n1 "--format=%H:%(trailers:key=Change-Id)" ,checkout-head))]
	    [(0 checkout-commit checkout-changeid) 'extract-changeid
	     (let ((tr-reg #rx"([0-9a-f]+):Change-Id: (I[0-9a-f]+)"))
	       (if (regexp-match-exact? tr-reg trailer-changeid)
		   (apply values (cons 0 (cdr (regexp-match tr-reg trailer-changeid))))
		   (values 1 #f #f)))])
	   (values 0 checkout-commit checkout-changeid)
	   (else (lambda (t)
		   (display (format "Error at ~a\n" t)
			    (current-error-port))
		   (values 1 #f ""))))
	  (values 0 #f (format "I~a" change-id-hash)))]

     [(0 related-to) 'get-related-to
      (if relate-to-change
	  (values 0 relate-to-change)
	  (values 0 0))]
     [(0 branch-arrange) 'cant-wrong
      (start-orphan ws-name checkout-head)]
     [(0 _) 'worktree-create
      (run/status+strings (git --git-dir ,(gerrit-dir)
			       worktree
			       add -b ,ws-name ,@branch-arrange))])
    (with-cwd
     ws-name
     (and-let*-tag-values-check
      ([(0 _) 'set-config-base-dir
	(run/status+strings
	 (git config --add ,(gerrit-config-name ,ws-name base-branch) ,base-branch-real))]
       [(0 _) 'set-config-related-to
	(run/status+strings
	 (git config --add ,(gerrit-config-name ,ws-name related-to) ,related-to))]
       [(0 _) 'set-changeid
	(run/status+strings
	 (git config --add ,(gerrit-config-name ,ws-name change-id) ,real-change-id))]
       [(0 _) 'set-last-upload
	(if last-uploaded
	    (run/status+strings
	     (git config --add ,(gerrit-config-name ,ws-name last-upload) ,last-uploaded))
	    (values 0 #f))]
       [(0 _) 'set-bare
	(run/status+strings
	 (git config --worktree --add "core.bare" "false"))]
       [(0 _) 'set-worktree
	(run/status+strings (git config --worktree --add "core.worktree" ,(format "~a" (current-directory))))]
       [(0 _) 'set-pull-rebase
	(run/status+strings
	 (git config --add ,(format "branch.~a.rebase" ws-name) "true"))])
      (display
       (format "Workspace ~a created" ws-name))
      (display
       (if (eq? related-to 0)
	   (format ".\n")
	   (format ", related to change ~a.\n" related-to)))
      (else (lambda (t)
	      (begin
		(display (format "Error at ~a\nReason: setup worktree config failed.\n" t)
			 (current-error-port))
		(exit 1))))))
    (else (lambda (t)
	    (let ((reason
		   (match t
		     ['check-exclusive
		      "Can't do both relate-change and resume-from"]
		     ['get-base-branch
		      (format "Can't determine the default branch, or can't find ~a"
			      (gerrit-dir))]
		     ['gen-change-id-hash
		      "Can't generate change-id."]
		     ['find-checkout-head
		      (format
		       "Can't find change num: ~a, maybe sync your repo"
		       (or relate-to-change resume-from-change))]
		     ['checkout-trailer
		      "Can't find Change-Id from commit message"]
		     ['extract-changeid
		      "Malformed Change-Id"]
		     [(or 'cant-resume 'duplicated-changeid)
		      "Can't resume from already merged change"]
		     ['worktree-create
		      "Can't create worktree."]
		     [_ "Misc errors."])))
	      (display (format "Error at ~a\n~a\n" t reason)
		       (current-error-port)))
	    (exit 1))))))


(define (max-of p l)
  (if (pair? l)
      (let loop ((init (car l))
		 (r (cdr l)))
	(if (pair? r)
	    (let ((h  (car r)))
	      (if (>  (p h) (p init))
		  (loop h (cdr r))
		  (loop init (cdr r))))
	    (values 0 init)))
      (values 1 #f)))

(define (find-max-ref refs)
  (and-let*-values-check
   (((0 ref-p) (max-of
		(lambda (x) (cdr x))
		(map (lambda (x)
		       (cons x (or
				(string->number
				 (car
				  (regexp-match #rx"[0-9]*$" x)))
				0))) refs)))
    ((0 ref) (if (eq? 0 (cdr ref-p))
		   (values 1 #f)
		   (values 0 (car ref-p)))))
   (values 0 ref)
   (else (values 1 #f))))

(define (find-change-max change-num)
  (and-let*-values-check
   (((0 refs)
     (run/status+strings (git --git-dir ,(gerrit-dir)
			      for-each-ref "--format=%(refname)"
			      ,(format "refs/changes/*/~a/*"
				       change-num))))
    ((0 max-ref)
     (find-max-ref refs)))
   (values 0 max-ref)
   (else (values 1 #f))))

(define (start-orphan name branch)
  (if (check-empty-base-branch branch)
      (values 0 `(--orphan ,name))
      (values 0 `(--no-track ,name ,branch))))

(define (print-status ws)
  (call/top-level
   ws (top-level)
   (lambda ()
     (let-values ([(ws-name need-upload rebase-suggestion rebase-from related-to change-id base-branch fork-point)
		   (get-status)])
       (display (format "Workspace \"~a\" targetting \"~a\",\n" ws-name base-branch))
       (unless (equal? related-to "0")
	 (display (format "  Related to Change: ~a,\n" related-to)))
       (display (format "Change-Message for Change-Id ~a:\n" change-id))
       (run (git log -n 1 "--format=medium" --color=never --grep ,(format "Change-Id: ~a" change-id)))
       (display ".\n")
       (when rebase-suggestion
	 (display (format "Upstream updated: can rebase to ~a from ~a,\n" rebase-suggestion rebase-from)))
       (display (if need-upload
		    "Has new work to upload, run `git gerrit upload`.\n"
		    "Workspace is clean, no upload needed.\n"))

       0))))

(define (gerrit-init repo-url)
  (and-let*-tag-values-check
   ([(0 _) 'mirror-repo
     (values (run (git clone --mirror ,repo-url ,(gerrit-dir))) #t)]
    [(0 _) 'config-worktree
     (run/status+strings (git --git-dir ,(gerrit-dir)
			      config --add extensions.worktreeConfig true))]
    [(0 dft-branch) 'find-def-branch
     (run/status+car-strings (git --git-dir ,(gerrit-dir)
				  symbolic-ref --short HEAD))]
    [(0 branch-arrange) 'never-wrong
     (start-orphan dft-branch dft-branch)]
    [(0 _) 'check-out-def-branch
     (run/status+strings (git --git-dir ,(gerrit-dir)
			      worktree add -b ,(format "local-~a" dft-branch)
			      ,@branch-arrange))])
   (with-cwd
    dft-branch
    (and-let*-tag-values-check
     ([(0 _) 'set-bare
       (run/status+strings (git config --worktree --add "core.bare" "false"))]
      [(0 _) 'set-worktree
       (run/status+strings (git config --worktree --add "core.worktree" ,(format "~a" (current-directory))))]
      [(0 _) 'set-pull-rebase
       (run/status+strings (git config --worktree --add "pull.ff" "only"))])
     (display
      (format "Dummy workspace ~a created.\n" dft-branch))
     (else (lambda (t)
	     (begin
	       (display (format "Error at ~a\nReason: setup worktree config failed.\n" t)
			(current-error-port))
	       (exit 1))))))
   (else (lambda (t)
	   (display (format "Error at ~a\n" t))))))


(define (sync-repo no-status)
  (let ((tpl (top-level)))
    (if tpl
	(begin
	  (with-cwd
	   (build-path tpl "..")
	   (abs-sync-repo))
	  (if (not no-status)
	      (print-status #f)
	      0))
	(if (directory-exists? (gerrit-dir))
	    (abs-sync-repo)
	    (begin
	      (display "Not in git directory.\n")
	      1)))))


(define (abs-sync-repo)
  (and-let*-tag-values-check
   ([(0 dft-branch) 'find-def-branch
     (run/status+car-strings (git --git-dir ,(gerrit-dir)
				  symbolic-ref --short HEAD))]
    [(0) 'remote-update
     (run (git --git-dir ,(gerrit-dir) remote update))]
    [(0) 'sync-main
     (with-cwd
      (build-path (gerrit-dir) ".." dft-branch)
      (run (git pull origin ,dft-branch)))])
   0
   (else (lambda (t)
	   (display (format "Error at: ~a" t)
		    (current-error-port))
	   (exit 1)))))


(define (workspace-rebase ws) ;; not finished
  (call/top-level
   ws (top-level)
   (lambda ()
     (let-values ([(ws-name need-upload
		      rebase-suggestion
		      rebase-from related-to
		      changeid
		      base-branch start-ref)
		   (get-status)])
       (if rebase-suggestion
	   (begin
	     (run (git rebase --onto ,rebase-suggestion ,rebase-from))
	     (when (equal? rebase-suggestion base-branch)
	       (run (git config --add ,(gerrit-config-name ,ws-name related-to) "0"))))
	   (begin
	     (display "No rebase needed.\n"
		      (current-error-port))
	     1))))))

(define (changeid->changenum change-id)
  (let ([lines
	 (run/strings
	  (git --git-dir ,(gerrit-dir)
	       for-each-ref
	       "--format=%(trailers:key=Change-Id,valueonly=true,separator=) %(refname)"
	       "refs/changes/**/*[0-9]"))])
    (let lp ([ls lines])
      (when (pair? ls)
	(let ([matched (regexp-match
			(format "~a refs/changes/[0-9]*/([0-9]*)/[0-9]*" change-id)
			(car ls))])
	  (if matched
	      (cadr matched)
	      (lp (cdr ls))))))))

(define (delete-workspace ws force?)
  (let-values ([(ws-n nots)
		(call/top-level
		 ws (top-level)
		 (lambda ()
		   (let-values ([(ws-name base-branch
					  related-to changeid
					  last-upload not-submitted)
				 (get-ws-config)])
		     (values ws-name not-submitted))))])
    (if (or force? (not nots))
	(and-let*-tag-values-check
	 ([(0) 'remove-worktree
	   (run (git --git-dir ,(gerrit-dir)
		     worktree remove ,ws))]
	  [(0) 'remove-branch
	   (run (git --git-dir ,(gerrit-dir)
		     branch -D ,ws-n))]
	  [(0) 'remove-config
	   (run (git --git-dir ,(gerrit-dir)
		     config --remove-section ,(gerrit-config-name ,ws-n)))])
	 0
	 (else (lambda
		   (t)
		 (display (format "Error at ~a.\n" t)
			  (current-error-port))
		 1)))
	(begin
	  (display (format "Workspace hasn't been submitted.\n")
		   (current-error-port))
	  1))))

(define start-workspace-cmd
  (let*
      ([cmd-name "workspace-start"]
       [cmd (lambda (args)
	      (let ((base-branch    (make-parameter #f))
		    (related-change (make-parameter #f))
		    (resume-from    (make-parameter #f)))
		(let ((ws-name
		       (command-line
			#:program (format "git-gerrit ~a" cmd-name)
			#:argv args
			#:once-each
			[("-b" "--base") base "The base branch to target."
			 (base-branch base)]
			#:once-any
			[("-r" "--related-to") relate "The change number to relate."
			 (related-change relate)]
			["--resume-from" resume "The change number to resume work from."
			 (resume-from resume)]
			#:usage-help
			"Create a workspace and start working on new change."
			#:args (ws-name)
			ws-name)))
		  (exit (start-workspace ws-name (base-branch) (related-change) (resume-from))))))])
    (hash-set! sub-commands cmd-name cmd)
    cmd))

(define sync-repo-cmd
  (let*
      ([cmd-name "sync"]
       [cmd
	(lambda (args)
	  (let ((flag-no-status (make-parameter #f)))
	    (begin (command-line
		    #:program (format "git-gerrit ~a" cmd-name)
		    #:argv args
		    #:once-each
		    ["--no-status" "Don't run status"
		     (flag-no-status #t)]
		    #:usage-help
		    "Sync from remote and optionally update workspace")
		   (exit (sync-repo (flag-no-status))))))])
    (hash-set! sub-commands cmd-name cmd)
    cmd))

(define delete-workspace-cmd
  (let*
      ([cmd-name "workspace-delete"]
       [cmd
	(lambda (args)
	  (let ((flag-force (make-parameter #f)))
	    (let ((ws
		   (command-line
		    #:program (format "git-gerrit ~a" cmd-name)
		    #:argv args
		    #:once-each
		    ["--force" "Force delete, even not merged"
		     (flag-force #t)]
		    #:usage-help
		    "Delete change workspace."
		    #:args (ws)
		    ws)))
	      (exit (delete-workspace ws (flag-force))))))])
    (hash-set! sub-commands cmd-name cmd)
    cmd))

(define init-repos-cmd
  (let*
      ([cmd-name "init"]
       [cmd (lambda (args)
	      (let ((repo-url
		     (command-line
		      #:program (format "git-gerrit ~a" cmd-name)
		      #:argv args
		      #:args (repo-url)
		      repo-url)))
		(exit (gerrit-init repo-url))))])
    (hash-set! sub-commands cmd-name cmd)
    cmd))

(define upload-change-cmd
  (let*
      ([cmd-name "upload"]
       [cmd (lambda  (args)
	      (let* ((no-sync (make-parameter #f))
		     (ws (command-line
			  #:program (format "git-gerrit ~a" cmd-name)
			  #:argv args
			  #:once-each
			  ["-n" "--no-sync" "Don't sync repo."
			   (no-sync #t)]
			  #:args ws
			  (if (pair? ws)
			      (car ws)
			      #f))))
		(exit (if (eq? 0 (upload-change ws))
			  (if (not (no-sync))
			      (sync-repo #t)
			      0)
			  1))))])
    (hash-set! sub-commands cmd-name cmd)
    cmd))

(define print-status-cmd
  (let*
      ([cmd-name "status"]
       [cmd (lambda (args)
	      (let ((ws (command-line
			 #:program (format "git-gerrit ~a" cmd-name)
			 #:argv args
			 #:args ws
			 (if (pair? ws)
			     (car ws)
			     #f))))
		(exit (print-status ws))))])
    (hash-set! sub-commands cmd-name cmd)
    cmd))

(define rebase-cmd
  (let*
      ([cmd-name "rebase"]
       [cmd (lambda (args)
	      (let ((dry-run (make-parameter #f)))
		(let ((ws
		       (command-line
			#:program (format "git-gerrit ~a" cmd-name)
			#:argv args
			#:once-each
			["--dry-run"  "Check only"
			 (dry-run #t)]
			#:usage-help
			"Check and pull --rebase from base branch for current workspace"
			#:args workspace
			(if (pair? workspace)
			    (car workspace)
			    #f))))
		  (if (dry-run)
		      (exit (print-status ws))
		      (exit (workspace-rebase ws))))))])
    (hash-set! sub-commands cmd-name cmd)
    cmd))

(define update-cl-cmd
  (let*
      ([cmd-name "modify-desc"]
       [cmd
	(lambda (args)
	  (begin (command-line
		  #:program (format "git-gerrit ~a" cmd-name)
		  #:argv args
		  #:usage-help
		  "Update commit message for current change.")
		 (exit
		  (let-values
		      ([(ws-name base-branch related-to changeid last-upload not-submitted)
			(get-ws-config)])
		    (if (get-a-new-message-commit base-branch changeid)
			0
			1)))))])
    (hash-set! sub-commands cmd-name cmd)
    cmd))

(define changeid-to-num
 (let*
     ([cmd-name "id2number"]
      [cmd
       (lambda (args)
	 (begin (command-line
		 #:program (format "git-gerrit ~a" cmd-name)
		 #:argv args
		 #:usage-help
		 "Find numeric change number from the Change-Id."
		 #:args (change-id)
		 (display (format "~a\n"
				  (changeid->changenum change-id))))))])
   (hash-set! sub-commands cmd-name cmd)
   cmd))

(define (global-ops args)
  (let
      ([temp-gerrit-dir (make-parameter #f)]
       [all-cmds (string-join (hash-keys sub-commands) " ")]
       )
    (parse-command-line
     "git-gerrit"
     args
     `((once-each
	[("--gerrit-dir")
	 ,(lambda (f g-dir)
	    (temp-gerrit-dir
	     (path->string (build-path g-dir "GERRIT")))
	    )
	 ("Specify gerrit dir, shall have \"GERRIT\"." "g-dir")]
	[("--trace")
	 ,(lambda (f) (scsh-trace #t))
	 ("Print git commands when executing.")])
       (usage-help
	,(format "\n<sub-command> is one of:\n  ~a"
		 all-cmds)))
     (lambda f #t)
     `("sub-command")
     )
    ;; (command-line #:program "git-gerrit"
    ;; 		  #:argv args
    ;; 		  #:once-each
    ;; 		  ["--gerrit-dir" g-dir "Specify gerrit dir, shall have \"GERRIT\"."
    ;; 		   (temp-gerrit-dir (path->string (build-path g-dir "GERRIT")))]
    ;; 		  ["--upload-prefix" u-p "The prefix added to remote refs when do upload"
    ;; 		   (upload-prefix u-p)]
    ;; 		  ["--trace" "Print commands"
    ;; 		   (scsh-trace #t)]
    ;; 		  #:ps
    ;; 		  ,all-cmds
    ;; 		  #:args sub-commnads
    ;; 		  #f
    ;; 		  )
    (let-values
	([(status temp-top-level)
	  (run/status+strings-suppress-error (git rev-parse --show-toplevel))])
      (if (eq? status 0)
	  (top-level (car temp-top-level))
	  #f))
    (if (temp-gerrit-dir)
	(gerrit-dir temp-gerrit-dir)
	(if (top-level)
	    (gerrit-dir (path->string (build-path (top-level) ".." "GERRIT")))
	    #f)))
  (void))

(define-namespace-anchor ns-a)
(define (debug args)
  (let ((ns (namespace-anchor->namespace ns-a)))
    (call-with-values
	(lambda ()
	  (eval 
	   (with-input-from-string (car args) read)
	   ns))
      (lambda x (display x) (newline)))))

(module+ main
  (define (main)
    (let ((chain-gargs
	   (lambda (gargs cmd args)
	     (global-ops gargs)
	     (cmd args))))
      (match (current-command-line-arguments)
	[(vector gargs ... (and cmd (? (lambda (x)
				       (hash-has-key?
					sub-commands x)))) args ...)
	 (chain-gargs gargs (hash-ref sub-commands cmd) args)]
	[(vector gargs ... "eval" args ...)
	 (chain-gargs gargs debug args)]
	[else (global-ops '("-h"))])))
  (main))
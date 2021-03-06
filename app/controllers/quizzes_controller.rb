#
# Copyright (C) 2011 Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

class QuizzesController < ApplicationController
  before_filter :require_context
  add_crumb("Quizzes") { |c| c.send :named_context_url, c.instance_variable_get("@context"), :context_quizzes_url }
  before_filter { |c| c.active_tab = "quizzes" }
  before_filter :get_quiz, :only => [:statistics, :edit, :show, :reorder, :history, :update, :destroy]
  
  def index
    if authorized_action(@context, @current_user, :read)
      return unless tab_enabled?(@context.class::TAB_QUIZZES)
      @quizzes = @context.quizzes.active.include_assignment.sort_by{|q| [(q.assignment ? q.assignment.due_at : q.lock_at) || Time.parse("Jan 1 2020"), q.title || ""]}
      @unpublished_quizzes = @quizzes.select{|q| !q.available?}
      @quizzes = @quizzes.select{|q| q.available?}
      @assignment_quizzes = @quizzes.select{|q| q.assignment_id} 
      @open_quizzes = @quizzes.select{|q| q.quiz_type == 'practice_quiz'} 
      @surveys = @quizzes.select{|q| q.quiz_type == 'survey' || q.quiz_type == 'graded_survey' }
      @submissions_hash = {}
      @submissions_hash
      @current_user.quiz_submissions.each{|s| @submissions_hash[s.quiz_id] = s } if @current_user
      log_asset_access("quizzes:#{@context.asset_string}", "quizzes", 'other')
    end
  end
  
  def new
    if authorized_action(@context.quizzes.new, @current_user, :create)
      @assignment = nil
      @assignment = @context.assignments.active.find(params[:assignment_id]) if params[:assignment_id]
      @quiz = @context.quizzes.create
      add_crumb((!@quiz.quiz_title || @quiz.quiz_title.empty? ? "New Quiz" : @quiz.quiz_title))
      # this is a weird check... who can create but not update???
      if authorized_action(@quiz, @current_user, :update)
        @assignment = @quiz.assignment
      end
      redirect_to(named_context_url(@context, :edit_context_quiz_url, @quiz))
    end
  end
  
  def has_student_submissions?
    @has_student_submissions ||= @quiz.quiz_submissions.any?{|s| @context.students.include?(s.user) }
    # !@quiz.quiz_submissions.select{|s| !@context.admins.include?(s.user) }.empty?
    @has_student_submissions
  end
  protected :has_student_submissions?
  
  def statistics
    if authorized_action(@quiz, @current_user, :manage)
      add_crumb(@quiz.title, named_context_url(@context, :context_quiz_url, @quiz))
      add_crumb("History", named_context_url(@context, :context_quiz_statistics_url, @quiz))
      @statistics = @quiz.statistics
      @submitted_users = User.find_all_by_id(@quiz.quiz_submissions.map(&:user_id)).compact.uniq.sort_by(&:last_name_first)
    end
  end
  
  def edit
    @assignment = @quiz.assignment
    if authorized_action(@quiz, @current_user, :update)
      add_crumb(@quiz.title, named_context_url(@context, :context_quiz_url, @quiz))
      student_ids = @context.students.map{|s| s.id }
      if has_student_submissions?
        flash[:notice] = "Keep in mind, some students have already taken or started taking this quiz"
      end
      render :action => "new"
    end
  end
  
  def show
    if @quiz.deleted?
      flash[:error] = "That quiz has been deleted"
      redirect_to named_context_url(@context, :context_quizzes_url)
      return
    end
    if authorized_action(@quiz, @current_user, :read)
      add_crumb(@quiz.title, named_context_url(@context, :context_quiz_url, @quiz))
      
      @headers = !params[:headless]
      
      @question_count = @quiz.question_count
      if session[:quiz_id] == @quiz.id && !request.xhr?
        session[:quiz_id] = nil
      end
      if @quiz.for_assignment?
        @locked_reason = @quiz.assignment.locked_for?(@current_user, :check_policies => true, :deep_check_if_needed => true)
        @locked = @locked_reason && !@quiz.grants_right?(@current_user, session, :update)
      else
        @locked_reason = @quiz.locked_for?(@current_user, :check_policies => true, :deep_check_if_needed => true) #&& !@quiz.grants_right?(@current_user, session, :update)#(@quiz.unlock_at && Time.now < @quiz.unlock_at) || (@quiz.lock_at && Time.now > @quiz.lock_at)
        @locked = !!@locked_reason
      end
      @quiz.context_module_action(@current_user, :read) if !@locked
      
      @submission = @quiz.quiz_submissions.find_by_user_id(@current_user.id, :order => 'created_at') rescue nil
      if !@current_user || (params[:preview] && @quiz.grants_right?(@current_user, session, :update))
        user_code = temporary_user_code
        @submission = @quiz.quiz_submissions.find_by_temporary_user_code(user_code)
      end
      @just_graded = false
      if @submission && @submission.needs_grading?
        @submission.grade_submission(:finished_at => @submission.end_at)
        @submission.reload
        @just_graded = true
      end
      managed_quiz_data if @quiz.grants_right?(@current_user, session, :grade)
      @stored_params = (@submission.temporary_data rescue nil) if params[:take] && @submission && @submission.untaken?
      @stored_params ||= OpenObject.new
      log_asset_access(@quiz, "quizzes", "quizzes")
      take_quiz if params[:take] && !@locked
    end
  end
  
  def managed_quiz_data
    @submissions = @quiz.quiz_submissions.to_a
    submission_ids = {}
    @submissions.each{|s| submission_ids[s.user_id] = s.id }
    submission_users = @submissions.map{|s| s.user_id}
    students = @context.students.find(:all, :order => :sortable_name).to_a
    @submitted_students = students.select{|stu| submission_ids[stu.id] }
    if @quiz.survey? && @quiz.anonymous_submissions
      @submitted_students = @submitted_students.sort_by{|stu| submission_ids[stu.id] }
    end
    @unsubmitted_students = students.reject{|stu| submission_ids[stu.id] }
  end
  protected :managed_quiz_data
  
  def take_quiz
    return unless authorized_action(@quiz, @current_user, :submit)
    if @submission && (!@submission.attempt || !@submission.submission_data)
      @submission.destroy
      @submission = nil
    end
    can_retry = @submission && (@quiz.unlimited_attempts? || @submission.attempts_left > 0 || @quiz.grants_right?(@current_user, session, :update))
    preview = params[:preview] && @quiz.grants_right?(@current_user, session, :update)
    if !@submission || (@submission.completed? && can_retry && !@just_graded) || preview
      if @quiz.access_code && !@quiz.access_code.empty? && params[:access_code] != @quiz.access_code
        render :action => 'access_code'
        return
      else
        user_code = @current_user 
        user_code = nil if preview
        user_code ||= temporary_user_code
        @submission = @quiz.generate_submission(user_code, !!preview)
      end
    end
    
    if @submission && !@submission.completed? && !@just_graded
      if !@quiz.access_code || @quiz.access_code.empty? || params[:access_code] == @quiz.access_code
        log_asset_access(@quiz, "quizzes", "quizzes", 'participate')
        render :action => "take_quiz"
      else
        render :action => 'access_code'
      end
    else
      if @just_graded
        if params[:take]
          redirect_to named_context_url(@context, :context_quiz_url, @quiz)
        end
      else
        flash[:error] = "You have no quiz attempts left"
      end
    end
  end
  protected :take_quiz
  
  def reorder
    if authorized_action(@quiz, @current_user, :update)
      items = []
      groups = @quiz.quiz_groups
      questions = @quiz.quiz_questions
      order = params[:order].split(",")
      order.each_index do |idx|
        name = order[idx]
        obj = nil
        id = name.gsub(/\A(question|group)_/, "").to_i
        obj = questions.detect{|q| q.id == id.to_i} if id != 0 && name.match(/\Aquestion/)
        obj.quiz_group_id = nil if obj.respond_to?("quiz_group_id=")
        obj = groups.detect{|g| g.id == id.to_i} if id != 0 && name.match(/\Agroup/)
        items << obj if obj
      end
      root_questions = @quiz.quiz_questions.find(:all, :conditions => 'quiz_group_id is null')
      items += root_questions
      items.uniq!
      question_updates = []
      group_updates = []
      items.each_with_index do |item, idx|
        if item.is_a?(QuizQuestion)
          question_updates << "WHEN id=#{item.id} THEN #{idx + 1}"
        else
          group_updates << "WHEN id=#{item.id} THEN #{idx + 1}"
        end
      end
      QuizQuestion.update_all("quiz_group_id=NULL,position=CASE #{question_updates.join(" ")} ELSE NULL END", {:id => items.select{|i| i.is_a?(QuizQuestion)}.map(&:id)}) unless question_updates.empty?
      QuizGroup.update_all("position=CASE #{group_updates.join(" ")} ELSE NULL END", {:id => items.select{|i| i.is_a?(QuizGroup)}.map(&:id)}) unless group_updates.empty?
      render :json => {:reorder => true}
    end
  end
  
  def history
    if authorized_action(@context, @current_user, :read)
      add_crumb(@quiz.title, named_context_url(@context, :context_quiz_url, @quiz))
      if params[:quiz_submission_id]
        @submission = @quiz.quiz_submissions.find(params[:quiz_submission_id])
      else
        user_id = @current_user.id
        user_id = params[:user_id] if params[:user_id] && @quiz.grants_right?(@current_user, session, :grade)
        @submission = @quiz.quiz_submissions.find_by_user_id(user_id, :order => 'created_at') rescue nil
      end
      @user = @submission && @submission.user
      if @submission && @submission.needs_grading?
        @submission.grade_submission(:finished_at => @submission.end_at)
        @submission.reload
      end
      if @quiz.deleted?
        flash[:error] = "That quiz has been deleted"
        redirect_to named_context_url(@context, :context_quizzes_url)
        return
      end
      if !@submission
        redirect_to named_context_url(@context, :context_quiz_url, @quiz)
        return
      end
      if authorized_action(@submission, @current_user, :read)
        add_crumb("History", named_context_url(@context, :context_quiz_history_url, @quiz))
        @headers = !params[:headless]
        @current_submission = @submission
        @version_instances = @submission.submitted_versions.sort_by{|v| v.version_number }
        params[:version] ||= @version_instances[0].version_number if @submission.untaken? && !@version_instances.empty?
        @current_version = true
        @version_number = "current"
        if params[:version]
          @version_number = params[:version].to_i
          @unversioned_submission = @submission
          @submission = @version_instances.detect{|s| s.version_number >= @version_number}
          @submission ||= @unversioned_submission.versions.get(params[:version]).model
          @current_version = (@current_submission.version_number == @submission.version_number)
          @version_number = "current" if @current_version
        end
        log_asset_access(@quiz, "quizzes", 'quizzes')
      end
    end
  end

  def create
    if authorized_action(@context.quizzes.new, @current_user, :create)
      params[:quiz][:title] = nil if params[:quiz][:title] == "undefined"
      params[:quiz][:title] ||= "New Quiz"
      params[:quiz].delete(:points_possible) unless params[:quiz][:quiz_type] == 'graded_survey'
      params[:quiz][:access_code] = nil if params[:quiz][:access_code] == ""
      if params[:quiz][:quiz_type] == 'assignment' || params[:quiz][:quiz_type] == 'graded_survey'
        params[:quiz][:assignment_group_id] ||= @context.assignment_groups.first.id
        @assignment_group = @context.assignment_groups.active.find_by_id(params[:quiz].delete(:assignment_group_id))
        if @assignment_group
          @assignment = @context.assignments.build(:title => params[:quiz][:title], :due_at => params[:quiz][:lock_at], :submission_types => 'online_quiz')
          @assignment.assignment_group = @assignment_group
          @assignment.saved_by = :quiz
          @assignment.save
          params[:quiz][:assignment_id] = @assignment.id
        end
        params[:quiz][:assignment_id] = nil unless @assignment
        params[:quiz][:title] = @assignment.title if @assignment
      end
      @quiz = @context.quizzes.build(params[:quiz])
      @quiz.content_being_saved_by(@current_user)
      @quiz.save
      if params[:activate]
        @quiz.generate_quiz_data
        @quiz.published_at = Time.now
        @quiz.workflow_state = 'available'
        @quiz.save
      end
      @quiz.did_edit if @quiz.created?
      
      render :json =>  @quiz.to_json(:include => {:assignment => {:include => :assignment_group}})
    end
  end
  
  def update
    n = Time.now.to_f
    if authorized_action(@quiz, @current_user, :update)
      logger.warn "QUIZZES_CONTROLLER: parsing parameters #{Time.now.to_f - n}"
      params[:quiz] ||= {}
      params[:quiz][:title] = "New Quiz" if params[:quiz][:title] == "undefined"
      params[:quiz].delete(:points_possible) unless params[:quiz][:quiz_type] == 'graded_survey'
      params[:quiz][:access_code] = nil if params[:quiz][:access_code] == ""
      if params[:quiz][:quiz_type] == 'assignment' || params[:quiz][:quiz_type] == 'graded_survey' #'new' && params[:quiz][:assignment_group_id]
        @assignment_group = @context.assignment_groups.active.find_by_id(params[:quiz].delete(:assignment_group_id))
        @assignment_group ||= @context.assignment_groups.first
        # The code to build an assignment for a quiz used to be here, but it's
        # been moved to the model quiz.rb instead.  See Quiz:build_assignment.
        params[:quiz][:assignment_group_id] = @assignment_group && @assignment_group.id
      end
      
      logger.warn "QUIZZES_CONTROLLER: activating quiz #{Time.now.to_f - n}"
      if params[:activate]
        @quiz.with_versioning(true) do
          @quiz.generate_quiz_data
          @quiz.workflow_state = 'available'
          @quiz.published_at = Time.now
          @quiz.save
        end
      end

      params[:quiz][:lock_at] = nil if params[:quiz].delete(:do_lock_at) == 'false'

      logger.warn "QUIZZES_CONTROLLER: marking as edited #{Time.now.to_f - n}"
      @quiz.with_versioning(false) do
        @quiz.did_edit if @quiz.created?
      end

      respond_to do |format|
        res = nil
        @quiz.content_being_saved_by(@current_user)
        @quiz.with_versioning(false) do
          res = @quiz.update_attributes(params[:quiz])
        end
        logger.warn "QUIZZES_CONTROLLER: updating attributes #{Time.now.to_f - n}"
        if res
          logger.warn "QUIZZES_CONTROLLER: reloading quiz #{Time.now.to_f - n}"
          @quiz.reload
          logger.warn "QUIZZES_CONTROLLER: rendering response #{Time.now.to_f - n}"
          flash[:notice] = "Quiz successfully updated"
          format.html { redirect_to named_context_url(@context, :context_quiz_url, @quiz) }
          format.json {render :json =>  @quiz.to_json(:include => {:assignment => {:include => :assignment_group}})}
        else
          flash[:error] = "Quiz failed to update"
          format.html { redirect_to named_context_url(@context, :context_quiz_url, @quiz) }
          format.json {render :json => @quiz.errors.to_json, :status => :bad_request}
        end
      end
    end
  end
  
  def destroy
    if authorized_action(@quiz, @current_user, :delete)
      respond_to do |format|
        if @quiz.destroy
          format.html { redirect_to course_quizzes_url(@context) }
          format.json { render :json => @quiz.to_json }
        else
          format.html { redirect_to course_quiz_url(@context, @quiz) }
          format.json { render :json => @quiz.errors.to_json }
        end
      end
    end
  end

  protected

  def get_quiz
    @quiz = @context.quizzes.find(params[:id] || params[:quiz_id])
    @quiz_name = @quiz.title
    @quiz
  end
end

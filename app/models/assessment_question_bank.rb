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

class AssessmentQuestionBank < ActiveRecord::Base
  include Workflow
  attr_accessible :context, :title, :user
  belongs_to :context, :polymorphic => true
  has_many :assessment_questions, :order => 'position, created_at'
  has_many :assessment_question_bank_users
  has_many :quiz_groups
  before_save :infer_defaults
  DEFAULT_IMPORTED_TITLE = 'Imported Questions'
  DEFAULT_UNFILED_TITLE = 'Unfiled Questions'
  adheres_to_policy
  
  workflow do
    state :active
    state :deleted
  end
  
  set_policy do
    given{|user, session| cached_context_grants_right?(user, session, :manage_assignments) }
    set { can :read and can :create and can :update and can :delete and can :manage }
    
    given{|user, session| user && self.assessment_question_bank_users.map(&:id).include?(user.id) }
    set { can :read }
  end

  def self.unfiled_for_context(context)
    context.assessment_question_banks.find_by_title_and_workflow_state(DEFAULT_UNFILED_TITLE, 'active') || context.assessment_question_banks.create(:title => DEFAULT_UNFILED_TITLE) rescue nil
  end
  
  def cached_context_short_name
    @cached_context_name ||= Rails.cache.fetch(['short_name_lookup', self.context_code].cache_key) do
      self.context.short_name rescue ""
    end
  end
  
  def assessment_question_count
    self.assessment_questions.active.count
  end
  
  def context_code
    "#{self.context_type.underscore}_#{self.context_id}"
  end
  
  def infer_defaults
    self.title = "No Name - #{self.context.name}" if !self.title || self.title.empty?
  end
  
  def bookmark_for(user, do_bookmark=true)
    if do_bookmark
      question_bank_user = self.assessment_question_bank_users.find_by_user_id(user.id)
      question_bank_user ||= self.assessment_question_bank_users.create(:user => user)
    else
      AssessmentQuestionBankUser.delete_all({:user_id => user.id, :assessment_question_bank_id => self.id})
    end
  end
  
  def bookmarked_for?(user)
    user && self.assessment_question_bank_users.map(&:user_id).include?(user.id)
  end
  
  def select_for_submission(count)
    ids = ActiveRecord::Base.connection.select_all("SELECT id FROM assessment_questions WHERE workflow_state != 'deleted' AND assessment_question_bank_id = #{self.id}")
    ids = ids.sort_by{rand}[0...count].map{|i|i['id']}
    AssessmentQuestion.find_all_by_id(ids)
  end
  
  named_scope :active, lambda {
    {:conditions => ['assessment_question_banks.workflow_state != ?', 'deleted'] }
  }
  named_scope :include_questions, lambda{
    {:include => :assessment_questions }
  }
end

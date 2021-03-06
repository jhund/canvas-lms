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

class PageComment < ActiveRecord::Base
  belongs_to :page, :polymorphic => true
  belongs_to :user
  validates_length_of :message, :maximum => maximum_text_length, :allow_nil => true, :allow_blank => true
  
  named_scope :for_user, lambda{|user|
    {:conditions => ['page_comments.user_id = ?', user.id]}
  }
  
  def user_name
    self.user.name rescue "Anonymous"
  end
end

# frozen_string_literal: true

# == Schema Information
#
# Table name: tags
#
#  id              :integer          not null, primary key
#  name            :string(255)      default("latest"), not null
#  repository_id   :integer          not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  user_id         :integer
#  digest          :string(255)
#  image_id        :string(255)      default("")
#  marked          :boolean          default(FALSE)
#  username        :string(255)
#  scanned         :integer          default(0)
#  vulnerabilities :text(65535)
#
# Indexes
#
#  index_tags_on_repository_id  (repository_id)
#  index_tags_on_user_id        (user_id)
#

# A tag as defined by Docker. It belongs to a repository and an author. The
# name follows the format as defined in registry/api/v2/names.go from Docker's
# Distribution project. The default name for a tag is "latest".
class Tag < ActiveRecord::Base
  serialize :vulnerabilities

  # NOTE: as a Hash because in Rails 5 we'll be able to pass a proper prefix.
  enum status: { scan_none: 0, scan_working: 1, scan_done: 2 }

  belongs_to :repository
  belongs_to :author, class_name: "User", foreign_key: "user_id", inverse_of: "tags"

  # We don't validate the tag, because we will fetch that from the registry,
  # and that's guaranteed to have a good format.
  #
  # See https://github.com/SUSE/Portus/pull/1494 on why we didn't use the
  # `uniqueness` constraint directly.
  #
  # NOTE: if we ever remove MySQL support, replace this with the proper
  # validator.
  validates :name, presence: true, unique_tag: true

  # Returns a string containing the username of the user that pushed this tag.
  def owner
    return author.display_username if author
    username.presence || "someone"
  end

  # Delete all the tags that match the given digest. Call this method if you
  # want to:
  #
  # - Safely remove tags (with its re-tags) on the DB.
  # - Remove the manifest digest on the registry.
  # - Preserve the activities related to the tags that are to be removed.
  #
  # Returns true on success, false otherwise.
  def delete_by_digest!(actor)
    dig = fetch_digest
    return false if dig.blank?

    Tag.where(digest: dig).update_all(marked: true)

    begin
      Registry.get.client.delete(repository.full_name, dig, "manifests")
    rescue StandardError => e
      Rails.logger.error "Could not delete tag on the registry: #{e.message}"
      return false
    end

    Tag.where(digest: dig).map { |t| t.delete_and_update!(actor) }
  end

  # Delete this tag and update its activity.
  def delete_and_update!(actor)
    logger.tagged("catalog") { logger.info "Removed the tag '#{name}'." }

    # If the tag is no longer there, ignore this call and return early.
    unless Tag.find_by(id: id)
      logger.tagged("catalog") { logger.info "Ignoring..." }
      return
    end

    # Delete tag and create the corresponding activities.
    destroy
    create_delete_activities!(actor)
  end

  # Returns vulnerabilities if there are any available and security scanning is
  # enabled.
  def fetch_vulnerabilities
    return unless ::Portus::Security.enabled?
    vulnerabilities if scanned == Tag.statuses[:scan_done]
  end

  # Updates the columns related to vulnerabilities with the given
  # attributes. This will apply to only this tag, or all tags sharing the same
  # digest (depending on whether the digest is known).
  def update_vulnerabilities(attrs = {})
    if digest.blank?
      update_columns(attrs)
    else
      Tag.where(digest: digest).update_all(attrs)
    end
  end

  protected

  # Fetch the digest for this tag. Usually the digest should already be
  # initialized since it's provided by the event notification that created this
  # tag. However, it might happen that the digest column is left blank (e.g.
  # legacy Portus, unknown error, etc). In these cases, this method will fetch
  # the manifest from the registry and update the column directly (skipping
  # validations).
  #
  # Returns a string containing the digest on success. Otherwise it returns
  # nil.
  def fetch_digest
    if digest.blank?
      client = Registry.get.client

      begin
        _, dig, = client.manifest(repository.full_name, name)
        update_column(:digest, dig)
        dig
      rescue StandardError => e
        Rails.logger.error "Could not fetch manifest digest: #{e.message}"
        nil
      end
    else
      digest
    end
  end

  # Create/update the activities for a delete operation.
  def create_delete_activities!(actor)
    PublicActivity::Activity.where(recipient: self).update_all(
      parameters: {
        namespace_id:   repository.namespace.id,
        namespace_name: repository.namespace.clean_name,
        repo_name:      repository.name,
        tag_name:       name
      }
    )

    # Create the delete activity.
    repository.create_activity(
      :delete,
      owner:      actor,
      recipient:  self,
      parameters: {
        repository_name: repository.name,
        namespace_id:    repository.namespace.id,
        namespace_name:  repository.namespace.clean_name,
        tag_name:        name
      }
    )
  end
end

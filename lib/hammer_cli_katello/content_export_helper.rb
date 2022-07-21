require 'hammer_cli_katello/repository'
require 'find'
# rubocop:disable ModuleLength
module HammerCLIKatello
  module ContentExportHelper
    include ApipieHelper
    def execute
      warn_unexportable_repositories
      response = super
      if option_async?
        emit_async_info
        HammerCLI::EX_OK
      elsif response != HammerCLI::EX_OK
        response
      else
        export_history = fetch_export_history_from_task(reload_task(@task))
        if syncable?
          make_listing_files(export_history)
          HammerCLI::EX_OK
        elsif export_history
          generate_metadata_json(export_history)
          HammerCLI::EX_OK
        else
          output.print_error _("Could not fetch the export history")
          HammerCLI::EX_CANTCREAT
        end
      end
    end

    def emit_async_info
      if syncable?
        output.print_message _("Once the task completes the listing files may be generated "\
            + "with the command:")
        output.print_message(" hammer content-export generate-listing --task-id #{@task['id']}")
      else
        output.print_message _("Once the task completes the export metadata must be generated "\
            + "with the command:")
        output.print_message(" hammer content-export generate-metadata --task-id #{@task['id']}")
      end
    end

    def syncable?
      options.key?("option_format") && option_format == 'syncable'
    end

    def send_request
      @task = super
    end

    def reload_task(task)
      task_id = if task.is_a? Hash
                  task['id']
                else
                  task
                end
      show(:foreman_tasks, id: task_id)
    end

    def fetch_export_history(export_history_id)
      return unless export_history_id
      index(:content_exports, :id => export_history_id).first
    end

    def fetch_export_history_from_task(task)
      # checking this here implies the task object was loaded recently
      if %w(error warning).include?(task['result'])
        raise _("Can not fetch export history from an unfinished task")
      end
      export_history_id = task.dig('output', 'export_history_id')
      fetch_export_history(export_history_id)
    end

    def make_listing_files(export_history)
      unless export_history["metadata"]["format"] == "syncable"
        raise _("Cannot generate listing files for this export since "\
          + "it is not syncable. It was not generated with --format=syncable.")
      end

      raise _("Export History does not have the path specified."\
        + " The task may have errored out.") unless export_history["path"]

      output.print_message _("Generated #{export_history['path']}")

      begin
        # export history path may look like
        # "/var/lib/pulp/exports/export-12803/apple/3.0//2022-06-30T17-23-06-00-00"
        # Generate listing files for all sub directories of
        # /var/lib/pulp/exports/export-12803/apple/3.0/$date/$org/Library/
        ignorables = Dir.glob("#{export_history['path']}/content/**/repodata").map do |path|
          File.dirname(path)
        end

        paths = Find.find("#{export_history['path']}/content").select do |path|
          File.directory?(path) &&
            ignorables.none? { |ignorable| path.start_with?(ignorable) }
        end

        paths.each do |dir|
          directories = Dir.chdir(dir) { Dir['*'] }
          File.write("#{dir}/listing", directories.join("\n"))
        end
      rescue SystemCallError
        output.print_message _("Unable to access/write listing files"\
                               + " to '#{export_history['path']}'." \
                               + " To generate listing files run the command below as a root user ")
        output.print_message(" hammer content-export generate-listing --id #{export_history['id']}")
      end
    end

    def generate_metadata_json(export_history)
      metadata_json = export_history["metadata"].to_json
      begin
        metadata_path = "#{export_history['path']}/metadata.json"
        File.write(metadata_path, metadata_json)
        output.print_message _("Generated #{metadata_path}")
      rescue SystemCallError
        filename = "metadata-#{export_history['id']}.json"
        File.write(filename, metadata_json)
        output.print_message _("Unable to access/write to '#{export_history['path']}'. "\
                               "Generated '#{Dir.pwd}/#{filename}' instead. "\
                               "This file is necessary to perform an import.")
      end
    end

    def version_command?
      self.class.command_name.first.to_sym == :version
    end

    def repository_command?
      self.class.command_name.first.to_sym == :repository
    end

    def fetch_repositories
      if repository_command?
        resp = show(:repositories, id: resolver.repository_id(options))
        return resp["download_policy"] == "immediate" ? [] : [resp]
      end

      repo_options = {
        library: true,
        content_type: 'yum',
        search: 'download_policy != immediate'
      }
      if version_command?
        repo_options[:content_view_version_id] = resolver.content_view_version_id(options)
      else
        repo_options[:organization_id] = options["option_organization_id"]
      end
      index(:repositories, repo_options)
    end

    def warn_unexportable_repositories
      repos = fetch_repositories
      unless repos.empty?
        if version_command?
          output.print_message _("NOTE: Unable to fully export this version because"\
            " it contains repositories without the 'immediate' download policy."\
            " Update the download policy and sync affected repositories."\
            " Once synced republish the content view"\
            " and export the generated version.")
        elsif repository_command?
          output.print_message _("NOTE: Unable to fully export this repository because"\
            " it does not have the 'immediate' download policy."\
            " Update the download policy, sync the repository and export.")
        else
          output.print_message _("NOTE: Unable to fully export this organization's library because"\
            " it contains repositories without the 'immediate' download policy."\
            " Update the download policy and sync affected"\
            " repositories to include them in the export.")
        end
        output.print_message _("Use the following command to update the "\
          "download policy of these repositories.")
        output.print_message "hammer repository update --id=<REPOSITORY_ID> "\
          "--download-policy='immediate'"
        output.print_message ""
        print_record(::HammerCLIKatello::Repository::ListCommand.output_definition, repos)
        exit(HammerCLI::EX_SOFTWARE) if repository_command? || option_fail_on_missing_content?
      end
    end

    def self.included(base)
      if base.command_name.first.to_sym == :version
        setup_version(base)
      elsif base.command_name.first.to_sym == :library
        setup_library(base)
      elsif base.command_name.first.to_sym == :repository
        setup_repository(base)
      end
    end

    def self.setup_repository(base)
      base.action(:repository)
      base.success_message _("Repository is being exported in task %{id}.")
      base.failure_message _("Could not export the repository")

      base.option "--name", "NAME", _("Filter repositories by name."),
                 :attribute_name => :option_name,
                 :required => false

      base.build_options do |o|
        o.expand(:all).including(:products, :organizations)
      end

      base.validate_options do
        any(:option_id, :option_name).required
        unless option(:option_id).exist?
          any(
            :option_product_id,
            :option_product_name
          ).required
          unless option(:option_product_id).exist?
            any(:option_organization_id, :option_organization_name, \
                                :option_organization_label).required
          end
        end
      end

      base.class_eval do
        def request_params
          super.tap do |opts|
            opts["id"] = resolver.repository_id(options)
          end
        end
      end
    end

    def self.setup_library(base)
      base.action(:library)
      base.success_message _("Library environment is being exported in task %{id}.")
      base.failure_message _("Could not export the library")
      base.option "--fail-on-missing-content", :flag,
                    _("Fails if any of the repositories belonging"\
                      " to this organization are unexportable.")

      base.build_options do |o|
        o.expand(:all).including(:organizations)
      end
    end

    def self.setup_version(base)
      base.action(:version)
      setup_version_options(base)
      base.success_message _("Content view version is being exported in task %{id}.")
      base.failure_message _("Could not export the content view version")

      base.extend_with(
        HammerCLIKatello::CommandExtensions::LifecycleEnvironments.new(only: :option_sources)
      )
      base.include(LifecycleEnvironmentNameMapping)

      base.class_eval do
        def request_params
          super.tap do |opts|
            opts["id"] = resolver.content_view_version_id(options)
          end
        end
      end
    end

    def self.setup_version_options(base)
      base.option "--fail-on-missing-content", :flag,
                    _("Fails if any of the repositories belonging"\
                      " to this version are unexportable.")

      base.option "--version", "VERSION", _("Filter versions by version number."),
                 :attribute_name => :option_version,
                 :required => false

      base.build_options do |o|
        o.expand(:all).including(:content_views, :organizations, :lifecycle_environments)
        o.without(:environment_ids, :environment_id)
      end

      base.validate_options do
        unless option(:option_id).exist?
          any(:option_id, :option_content_view_name, :option_content_view_id).required
          any(
            :option_version,
            :option_lifecycle_environment_id,
            :option_lifecycle_environment_name
          ).required
          unless option(:option_content_view_id).exist?
            any(:option_organization_id, :option_organization_name, \
                                :option_organization_label).required
          end
        end
      end
    end
  end
end

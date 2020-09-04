class RMT::CLI::Mirror < RMT::CLI::Base
  desc 'all', _('Mirror all enabled repositories')
  def all
    RMT::Lockfile.lock('mirror') do
      begin
        mirror.mirror_suma_product_tree(repository_url: 'https://scc.suse.com/suma/')
      rescue RMT::Mirror::Exception => e
        errors << _('Mirroring SUMA product tree failed: %{error_message}') % { error_message: e.message }
      end

      raise RMT::CLI::Error.new(_('There are no repositories marked for mirroring.')) if Repository.only_mirroring_enabled.empty?

      # The set of repositories to be mirrored can change while the command is
      # mirroring. Hence, the iteration uses a until loop to ensure no
      # repositories have been left unmirrored.
      mirrored_repo_ids = []
      until (repos = Repository.only_mirroring_enabled.where.not(id: mirrored_repo_ids)).empty?
        repo_ids = mirror_repos!(repos)

        mirrored_repo_ids.concat(repo_ids)
      end

      finish_execution
    end
  end

  default_task :all

  desc 'repository IDS', _('Mirror enabled repositories with given repository IDs')
  def repository(*ids)
    RMT::Lockfile.lock('mirror') do
      ids = clean_target_input(ids)
      raise RMT::CLI::Error.new(_('No repository IDs supplied')) if ids.empty?

      mirror_repos!(ids)
      finish_execution
    end
  end

  desc 'product IDS', _('Mirror enabled repositories for a product with given product IDs')
  def product(*targets)
    RMT::Lockfile.lock('mirror') do
      targets = clean_target_input(targets)
      raise RMT::CLI::Error.new(_('No product IDs supplied')) if targets.empty?

      repos = []
      targets.each do |target|
        products = Product.get_by_target!(target)
        errors << _('Product for target %{target} not found') % { target: target } if products.empty?
        products.each do |product|
          product_repos = product.repositories.only_mirroring_enabled
          errors << _('Product %{target} has no repositories enabled') % { target: target } if product_repos.empty?
          repos += product_repos.to_a
        end
      rescue ActiveRecord::RecordNotFound
        errors << _('Product with ID %{target} not found') % { target: target }
      end

      mirror_repos!(repos)
      finish_execution
    end
  end

  protected

  def logger
    @logger ||= RMT::Logger.new($stdout)
  end

  def mirror
    @mirror ||= RMT::Mirror.new(logger: logger, mirror_src: RMT::Config.mirror_src_files?)
  end

  def errors
    @errors ||= []
  end

  def mirror_repos!(targets)
    mirrored_repo_ids = []

    targets.each do |target|
      repo, repo_error = find_repo_by_target(target)
      next (errors << repo_error) if repo_error

      mirror.mirror(
        repository_url: repo.external_url,
        local_path: Repository.make_local_path(repo.external_url),
        auth_token: repo.auth_token,
        repo_name: repo.name
      )
      repo.refresh_timestamp!
    rescue RMT::Mirror::Exception => e
      errors << _("Repository '%{repo_name}' (%{repo_id}): %{error_message}") % {
        repo_id: repo.id, repo_name: repo.name, error_message: e.message
      }
    ensure
      mirrored_repo_ids << repo.id if repo
    end

    mirrored_repo_ids
  end

  def find_repo_by_target(target)
    repo = target.is_a?(Repository) ? target : Repository.find_by(scc_id: target)

    error =
      if repo.nil?
        _('Repository with ID %{repo_id} not found') % { repo_id: target }
      elsif repo.mirroring_enabled
        nil
      else
        _('Mirroring of repository with ID %{repo_id} is not enabled') % { repo_id: repo.scc_id }
      end

    [repo, error]
  end

  def finish_execution
    if errors.empty?
      logger.info("\e[32m" + _('Mirroring complete.') + "\e[0m")
    else
      errors_list = errors.map { |e| e.end_with?('.') ? e : e + '.' }.join("\n")
      raise RMT::CLI::Error.new(
        "\e[33m" + _('Mirroring completed with errors.') + "\e[0m\n" +
        _('The following errors ocurred while mirroring:%{errors_list}') % {
          errors_list: "\n\e[31m" + errors_list + "\e[0m"
        }
      )
    end
  end
end

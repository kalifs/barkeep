#
# Sinatra routes which implement the Admin pages.
#
require "resque_jobs/clone_new_repo"
require "resque_jobs/delete_repo"
require "addressable/uri"
require "fileutils"

class Barkeep < Sinatra::Base
  before "/admin*" do
    unless current_user.admin?
      message = "You do not have permission to view this admin page."
      message += " <a href='/signin'>Sign in</a>." unless logged_in?
      halt 400, message
    end
  end

  # A page to help keep track of Barkeep's data models and background processes. Also see the Resque dashboard
  # (/resque).
  get "/admin/?" do
    admin_erb :index
  end

  get "/admin/diagnostics?" do
    admin_erb :diagnostics, :locals => {
      :most_recent_commit => Commit.order(:id.desc).first,
      :most_recent_comment => Comment.order(:id.desc).first,
      :repos => MetaRepo.instance.repos.map(&:name),
      :failed_email_count => CompletedEmail.filter(:result => "failure").count,
      :recently_failed_emails =>
          CompletedEmail.filter(:result => "failure").order(:created_at.desc).limit(10).all,
      :pending_comments => Comment.filter(:has_been_emailed => false).order(:id.asc).limit(10).all,
      :pending_comments_count => Comment.filter(:has_been_emailed => false).count,
    }
  end

  get "/admin/users/?" do
    # Don't show the demo user. It's confusing.
    users = User.filter("permission != 'demo'").order_by(:name).all
    admin_erb :manage_users, :locals => { :users => users }
  end

  post "/admin/users/update_permissions" do
    # Don't allow a user to remove their own admin privileges, because then you can no longer use the
    # admin pages. It's a confusing experience.
    user = User.first(:id => params[:user_id])
    next if current_user == user
    halt 400 unless ["normal", "admin"].include? params[:permission]
    user.permission = params[:permission]
    user.save
    nil
  end

  get "/admin/repos/?" do
    MetaRepo.instance.scan_for_new_repos
    # TODO(philc): Currently importing.
    git_repos = GitRepo.all.sort_by(&:name)
    repos_hashes = git_repos.map do |git_repo|
      {
        :git_repo => git_repo,
        :grit_repo => MetaRepo.instance.get_grit_repo(git_repo.name),
        :newest_commit => git_repo.commits_dataset.order(:id.desc).first
      }
    end

    # As of April 2012, we can have GitRepo records in the database which have no corresponding repo on disk,
    # because that repo was moved or deleted. Do not include these old repos in the admin page.
    repos_hashes.reject! { |repo_hash| repo_hash[:grit_repo].nil? }

    log_directory = File.expand_path(File.join(File.dirname(__FILE__), "../log"))
    # NOTE(philc): Native ruby would be better, but I was too lazy to find a better solution.
    tail_log = Proc.new { |log_file| `tail -n 20 '#{File.join(log_directory, log_file)}'` }
    admin_erb :repos, :locals => {
      :repos_hashes => repos_hashes,
      :repos_being_cloned => repos_being_cloned,
      :clone_new_repo_log => tail_log.call("clone_new_repo.log"),
      :fetch_commits_log => tail_log.call("fetch_commits.log")
    }
  end

  # Schedules a Git repo to be cloned.
  #  - url
  post "/admin/repos/create_new_repo" do
    halt 400, "'url' is required." if (params[:url] || "").strip.empty?
    halt 400, "This is not a valid URL." unless Addressable::URI.parse(params[:url])
    repo_name = File.basename(params[:url], ".*")
    repo_path = File.join(REPOS_ROOT, repo_name)
    halt 400, "There is already a folder named \"#{repo_name}\" in #{REPOS_ROOT}." if File.exists?(repo_path)
    Resque.enqueue(CloneNewRepo, repo_name, params[:url])
    nil
  end

  post "/admin/repos/delete_repo" do
    Resque.enqueue(DeleteRepo, params[:name])
    nil
  end

  # You can view log files from within the UI.
  get "/admin/log/:file_name" do
    next if params[:file_name].include?("..")
    content_type "text/plain"
    `tail -n 500 log/#{params[:file_name]}`
  end

  helpers do
    def admin_page_breadcrumb(display_name)
      %Q(<div id="adminBreadcrumb"><a href="/admin">Admin</a> &raquo; #{display_name}</div>)
    end
  end

  private

  def repos_being_cloned
    # Resque jobs look like: { "class"=>"CloneNewRepo", "args"=>["repo_name", "repo_url"] }
    jobs = Resque.peek("clone_new_repo", 0, 25)
    jobs.map { |job| job["args"][1] }
  end

  def admin_erb(view, view_params = {})
    # NOTE(philc): This use of nested Sinatra layouts is a little klunky. It's the best approach I could find.
    html_with_admin_layout = erb("admin/#{view}".to_sym, { :layout => :"admin/layout" }.merge(view_params))
    erb html_with_admin_layout
  end
end

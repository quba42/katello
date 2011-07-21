#
# Copyright 2011 Red Hat, Inc.
#
# This software is licensed to you under the GNU General Public
# License as published by the Free Software Foundation; either version
# 2 of the License (GPLv2) or (at your option) any later version.
# There is NO WARRANTY for this software, express or implied,
# including the implied warranties of MERCHANTABILITY,
# NON-INFRINGEMENT, or FITNESS FOR A PARTICULAR PURPOSE. You should
# have received a copy of GPLv2 along with this software; if not, see
# http://www.gnu.org/licenses/old-licenses/gpl-2.0.txt.

class NotInLockerValidator < ActiveModel::Validator
  def validate(record)
    record.errors[:environment] << _("Locker environment can have no changeset!") if record.environment.locker?
  end
end

class Changeset < ActiveRecord::Base
  include Authorization
  include AsyncOrchestration

  NEW = 'new'
  REVIEW = 'review'
  PROMOTED = 'promoted'
  STATES = [NEW, REVIEW, PROMOTED]

  validates_inclusion_of :state,
    :in => STATES,
    :allow_blank => false,
    :message => "A changeset must have one of the following states: #{STATES.join(', ')}."

  validates :name, :presence => true, :allow_blank => false
  validates_uniqueness_of :name, :scope => :environment_id, :message => N_("Must be unique within an environment")
  validates :environment, :presence=>true
  validates_with NotInLockerValidator
  has_and_belongs_to_many :products, :uniq => true
  has_many :packages, :class_name=>"ChangesetPackage", :inverse_of=>:changeset
  has_many :users, :class_name=>"ChangesetUser", :inverse_of=>:changeset
  has_many :errata, :class_name=>"ChangesetErratum", :inverse_of=>:changeset
  has_many :repos, :class_name=>"ChangesetRepo", :inverse_of => :changeset
  belongs_to :environment, :class_name=>"KPEnvironment"
  before_save :uniquify_artifacts

  scoped_search :on => :name, :complete_value => true, :rename => :'changeset.name'
  scoped_search :on => :created_at, :complete_value => true, :rename => :'changeset.create_date'
  scoped_search :on => :promotion_date, :complete_value => true, :rename => :'changeset.promotion_date'
  scoped_search :in => :products, :on => :name, :complete_value => true, :rename => :'custom_product.name'
  scoped_search :in => :products, :on => :description, :complete_value => true, :rename => :'custom_product.description'

  def key_for item
    "changeset_#{id}_#{item}"
  end

  def package_ids
    packages.collect{|pack| pack.package_id}
  end

  def errata_ids
    errata.collect{|erratum| erratum.errata_id}
  end

  #get a list of all the products involved in teh changeset
  #  but not necessarily 'in' the changeset
  def involved_products
    to_ret = self.products.clone #get a copy
    to_ret =  to_ret + self.packages.collect{|pkg| pkg.product}
    to_ret =  to_ret + self.errata.collect{|pkg| pkg.product}
    to_ret =  to_ret + self.repos.collect{|pkg| pkg.product}
    to_ret.uniq
  end

  def dependencies
    from_env = self.environment
    to_env   = self.environment.successor

    repoids = []

    #get source repos to depsolve for
    from_env.products.each{|prod|
      repoids += prod.repos(from_env).collect{|repo| repo.id}
    }

    #TODO  look up NEVRA from pulp instead of relying on display_name
    #   will this be too expensive?  should display_name be "formalized"
    changelog_pkgs = self.packages.collect{|pkg| pkg.display_name}


    #pulp can't handle an empty package list
    return [] if changelog_pkgs.empty?

    all_pkgs = Pulp::Package.dep_solve(changelog_pkgs, repoids).collect do |package|
         Glue::Pulp::Package.new(package)
    end

    #remove pkgs that are in the target environment's repos
    repo_pkg_ids = []
    to_env.products do |prod|
      prod.repos to_env do |repo|
        repo_pkg_ids += repo.packages.collect{|pkg| pkg.id}
      end
    end

    uniq_pkgs = []
    all_pkgs.each {|pkg|
      uniq_pkgs << pkg if repo_pkg_ids.index(pkg.id).nil?
    }

    uniq_pkgs

  end

  # returns list of virtual permission tags for the current user
  def self.list_tags
    select('id,name').all.collect { |m| VirtualTag.new(m.id, m.name) }
  end

  def promote
    raise _("Cannot promote a changeset when it is not in the reivew phase") if self.state != Changeset::REVIEW

    from_env = self.environment.prior
    to_env   = self.environment

    wait_for_tasks promote_products(from_env, to_env)
    wait_for_tasks promote_repos(from_env, to_env)
    promote_packages from_env, to_env
    promote_errata   from_env, to_env

    self.promotion_date = Time.now
    self.state = Changeset::PROMOTED
    self.save!
  end

  def wait_for_tasks async_tasks
    async_tasks = async_tasks.collect do |t|
      ts = TaskStatus.using_pulp_task(t)
      ts.organization = self.environment.organization
      ts
    end

    any_running = true
    while any_running
      any_running = false
      for t in async_tasks
        t.refresh
        if ((t.state == TaskStatus::Status::WAITING) or (t.state == TaskStatus::Status::RUNNING))
          any_running = true
          break
        end
      end
    end

    async_tasks
  end

  def add_product product_name
    from_env = self.environment.prior

    prod = from_env.products.find_by_name(product_name)
    raise Errors::ChangesetContentException.new("Product not found within environment you want to promote from.") if prod.nil?
    self.products << prod
    prod
  end

   def add_package package_name
    self.environment.prior.products.each do |product|
      product.repos(self.environment.prior).each do |repo|
        #search for package in all repos in a product
        idx = repo.packages.index do |p| p.name == package_name end
        if idx != nil
          pack = repo.packages[idx]
          self.packages << ChangesetPackage.new(:package_id => pack.id, :display_name => package_name, :product_id => product.id, :changeset => @changeset)
          return
        end
      end
    end
    raise Errors::ChangesetContentException.new("Package not found within this environment.")
   end

  def add_erratum erratum_id
    self.environment.prior.products.each do |product|
      product.repos(self.environment.prior).each do |repo|
        #search for erratum in all repos in a product
        idx = repo.errata.index do |e| e.id == erratum_id end
        if idx != nil
          erratum = repo.errata[idx]
          self.errata << ChangesetErratum.new(:errata_id => erratum.id, :display_name => erratum_id, :product_id => product.id, :changeset => @changeset)
          return
        end
      end
    end
    raise Errors::ChangesetContentException.new("Erratum not found within this environment.")
  end

  def add_repo repo_name
    self.environment.prior.products.each do |product|
      repos = product.repos(self.environment.prior)
      idx = repos.index do |r| r.name == repo_name end
      if idx != nil
        repo = repos[idx]
        self.repos << ChangesetRepo.new(:repo_id => repo.id, :display_name => repo_name, :product_id => product.id, :changeset => @changeset)
        return
      end
    end
    raise Errors::ChangesetContentException.new("Repository not found within this environment.")
  end

  def remove_product product_name
    prod = self.environment.products.find_by_name(product_name)
    self.products.delete(prod)
  end

  def remove_package package_name
    self.environment.prior.products.each do |product|
      product.repos(self.environment).each do |repo|
        #search for package in all repos in a product
        idx = repo.packages.index do |p| p.name == package_name end
        if idx != nil
          pack = repo.packages[idx]
          ChangesetPackage.destroy_all(:package_id => pack.id, :changeset_id => self.id)
          return
        end
      end
    end
  end

  def remove_erratum erratum_id
    self.environment.prior.products.each do |product|
      product.repos(self.environment).each do |repo|
        #search for erratum in all repos in a product
        idx = repo.errata.index do |e| e.id == erratum_id end
        if idx != nil
          erratum = repo.errata[idx]
          ChangesetErratum.destroy_all(:errata_id => erratum.id, :changeset_id => self.id)
          return
        end
      end
    end
  end

  def remove_repo repo_name
    self.environment.prior.products.each do |product|
      repos = product.repos(self.environment)
      idx = repos.index do |r| r.name == repo_name end
      if idx != nil
        repo = repos[idx]
        ChangesetRepo.destroy_all(:repo_id => repo.id, :changeset_id => self.id)
        return
      end
    end
  end

  #TODO: add validation


  private

  def products_to_promote from_env, to_env
    #promote all products stacked for promotion + (products required by packages,errata & repos - products in target env)
    required_products = []
    required_products << self.packages.collect do |p| Product.find(p.product_id) end
    required_products << self.errata.collect do |e|   Product.find(e.product_id) end
    required_products << self.repos.collect do |r|    Product.find(r.product_id) end
    required_products = required_products.flatten(1)
    products_to_promote = (self.products + (required_products - to_env.products)).uniq
    products_to_promote
  end

  def promote_products from_env, to_env
    async_tasks = products_to_promote(from_env, to_env).collect do |product|
      product.promote from_env, to_env
    end
    async_tasks.flatten(1)
  end


  def promote_repos from_env, to_env
    async_tasks = []

    for r in self.repos
      product = r.product
      repo    = Glue::Pulp::Repo.find(r.repo_id)

      next if products_to_promote(from_env, to_env).include? product

      if repo.is_cloned_in?(to_env)
        async_tasks << repo.sync
      else
        async_tasks << repo.promote(to_env, product)
      end
    end
    async_tasks
  end


  def promote_packages from_env, to_env
    #repo->list of pkg_ids
    pkgs_promote = {}

    for pkg in self.packages
      product = pkg.product

      next if products_to_promote(from_env, to_env).include? product

      product.repos(from_env).each do |repo|
        clone = Glue::Pulp::Repo.find(Glue::Pulp::Repos.clone_repo_id(repo.id, to_env.name))

        if (repo.has_package? pkg.package_id) and (!clone.has_package? pkg.package_id)
          pkgs_promote[clone] ||= []
          pkgs_promote[clone] << pkg.package_id
        end
      end
    end

    pkgs_promote.each_pair do |repo, pkgs|
      repo.add_packages(pkgs)
    end
  end


  def promote_errata from_env, to_env
    #repo->list of errata_ids
    errata_promote = {}

    for err in self.errata
      product = err.product

      next if products_to_promote(from_env, to_env).include? product

      product.repos(from_env).each do |repo|
        clone = Glue::Pulp::Repo.find(Glue::Pulp::Repos.clone_repo_id(repo.id, to_env.name))

        if (repo.has_erratum? err.errata_id) and (!clone.has_erratum? err.errata_id)
          errata_promote[clone] ||= []
          errata_promote[clone] << err.errata_id
        end
      end
    end

    errata_promote.each_pair do |repo, errata|
      repo.add_errata(errata)
    end
  end


  def uniquify_artifacts
    self.products.uniq! unless self.products.nil?
    [[:packages,:package_id],[:errata, :errata_id],[:repos, :repo_id]].each do |items, item_id|
      unless self.send(items).nil?
        s = Set.new
        # for some reason uniq! with a closure didn''t work
        # so invented an equivalent
        self.send(items).reject! do |item|
          includes = s.include? item.send(item_id)
          s.add(item.send(item_id)) unless includes
          includes
        end
      end
    end
  end

end

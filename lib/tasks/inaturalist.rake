namespace :inaturalist do
  desc "Copy example config files."
  task :setup do
    Dir.glob("#{Rails.root}/config/*.example").each do |file|
      example = File.basename(file)
      file = File.basename(example, '.example')
      if File.exists?(Rails.root.join('config', file))
        puts "#{file} already exists."
      else
        cp Rails.root.join('config', example), Rails.root.join('config', file)
      end
    end
    exit 0
  end

  desc "Set the public_positional_accuracy and mappable fields on observations."
  task :update_public_accuracy => :environment do
    batch = 0
    batch_size = 10000
    total_observations = Observation.count
    total_batches = (total_observations / batch_size).ceil
    start_time = Time.now
    Observation.includes(:quality_metrics).find_in_batches(batch_size: batch_size) do |observations|
      puts "Starting batch #{ batch += 1 } of #{ total_batches } at #{ (Time.now - start_time).round(2) } seconds"
      Observation.connection.transaction do
        observations.each do |o|
          o.update_public_positional_accuracy
          o.update_mappable
        end
      end
    end
  end

  desc "Delete content from spmmer accounts."
  task :delete_spam_content => :environment do
    spammer_ids = User.where(spammer: true).
      where("suspended_at < ?", User::DELETE_SPAM_AFTER.ago).
      collect(&:id)
    Comment.where(user_id: spammer_ids).destroy_all
    Guide.where(user_id: spammer_ids).destroy_all
    Identification.where(user_id: spammer_ids).destroy_all
    List.where(user_id: spammer_ids).where("lists.type != 'LifeList'").destroy_all
    Observation.where(user_id: spammer_ids).destroy_all
    Post.where(user_id: spammer_ids).destroy_all
    Project.where(user_id: spammer_ids).destroy_all
    User.where(id: spammer_ids).update_all(description: nil)
  end

  desc "Delete expired updates"
  task :delete_expired_updates => :environment do
    min_id = UpdateAction.minimum(:id)
    # using an ID clause to limit the number of rows in the query
    last_id_to_delete = UpdateAction.where(["created_at < ?", 3.months.ago]).
      where("id < #{ min_id + 1000000 }").maximum(:id)
    UpdateAction.delete_and_purge("id <= #{ last_id_to_delete }")
    # delete anything that may be left in Elasticsearch
    try_and_try_again( Elasticsearch::Transport::Transport::Errors::Conflict, sleep: 1, tries: 10 ) do
      Elasticsearch::Model.client.delete_by_query(index: UpdateAction.index_name,
        body: { query: { range: { id: { lte: last_id_to_delete } } } })
    end

    # # suspend subscriptions of users with no viewed updates
    # Update.select(:subscriber_id).group(:subscriber_id).having("max(viewed_at) IS NULL").
    #   order(:subscriber_id).pluck(:subscriber_id).each_slice(500) do |batch|
    #   # get this batch's users
    #   users_to_suspend = User.where(id: batch.compact).where(subscriptions_suspended_at: nil)
    #   # send them emails that we're suspending their subscriptions
    #   users_to_suspend.each do |u|
    #     Emailer.user_updates_suspended(u).deliver_now
    #   end
    #   # suspend their subscriptions
    #   User.where(id: users_to_suspend.pluck(:id)).update_all(subscriptions_suspended_at: Time.now)
    # end
  end

  desc "Delete expired S3 photos"
  task :delete_expired_photos => :environment do
    S3_CONFIG = YAML.load_file(File.join(Rails.root, "config", "s3.yml"))
    # Aws.config(access_key_id: S3_CONFIG["access_key_id"],
    #   secret_access_key: S3_CONFIG["secret_access_key"], region: "us-east-1")
    # bucket = Aws::S3.new.buckets[CONFIG.s3_bucket]
    client = ::Aws::S3::Client.new(
      access_key_id: S3_CONFIG["access_key_id"],
      secret_access_key: S3_CONFIG["secret_access_key"],
      region: CONFIG.s3_region
    )

    fails = 0
    DeletedPhoto.still_in_s3.
      joins("LEFT JOIN photos ON (deleted_photos.photo_id = photos.id)").
      where("photos.id IS NULL").
      where("(orphan=false AND deleted_photos.created_at <= ?)
        OR (orphan=true AND deleted_photos.created_at <= ?)",
        6.months.ago, 1.month.ago).select(:id, :photo_id).find_each do |p|
      images = client.list_objects( bucket: CONFIG.s3_bucket, prefix: "photos/#{ p.photo_id }/" ).contents
      if images.any?
        pp images
        begin
          client.delete_objects( bucket: CONFIG.s3_bucket, delete: { objects: images.map{|s| { key: s.key } } } )
          p.update_attributes(removed_from_s3: true)
        rescue
          fails += 1
          break if fails >= 5
        end
      end
    end
  end

  desc "Delete expired S3 sounds"
  task :delete_expired_sounds => :environment do
    S3_CONFIG = YAML.load_file(File.join(Rails.root, "config", "s3.yml"))
    client = ::Aws::S3::Client.new(
      access_key_id: S3_CONFIG["access_key_id"],
      secret_access_key: S3_CONFIG["secret_access_key"],
      region: CONFIG.s3_region
    )

    fails = 0
    DeletedSound.still_in_s3.
      joins("LEFT JOIN sounds ON (deleted_sounds.sound_id = sounds.id)").
      where("sounds.id IS NULL").
      where("(orphan=false AND deleted_sounds.created_at <= ?)
        OR (orphan=true AND deleted_sounds.created_at <= ?)",
        6.months.ago, 1.month.ago).select(:id, :sound_id).find_each do |s|
      sounds = client.list_objects( bucket: CONFIG.s3_bucket, prefix: "sounds/#{ s.sound_id }." ).contents
      if sounds.any?
        pp sounds
        begin
          client.delete_objects( bucket: CONFIG.s3_bucket, delete: { objects: sounds.map{|s| { key: s.key } } } )
          s.update_attributes(removed_from_s3: true)
        rescue
          fails += 1
          break if fails >= 5
        end
      end
    end
  end

  desc "Delete orphaned photos"
  task :delete_orphaned_photos => :environment do
    first_id = Photo.minimum(:id)
    last_id = Photo.maximum(:id)
    index = 0
    batch_size = 10000
    # using `where id BETWEEN` instead of .find_each or similar, which use
    # LIMIT and create fewer, but longer-running queries
    while index <= last_id
      photos = Photo.joins("left join observation_photos op on (photos.id=op.photo_id)").
        joins("left join taxon_photos tp on (photos.id=tp.photo_id)").
        joins("left join guide_photos gp on (photos.id=gp.photo_id)").
        where("op.id IS NULL and tp.id IS NULL and gp.id IS NULL").
        where("photos.id BETWEEN ? AND ?", index, index + batch_size)
      photos.each do |p|
        # set the orphan attribute on Photo, which will set the same on DeletedPhoto
        p.orphan = true
        p.destroy
      end
      index += batch_size
    end
  end

  desc "Delete orphaned sounds"
  task :delete_orphaned_sounds => :environment do
    first_id = Sound.minimum(:id)
    last_id = Sound.maximum(:id)
    index = 0
    batch_size = 10000
    # using `where id BETWEEN` instead of .find_each or similar, which use
    # LIMIT and create fewer, but longer-running queries
    while index <= last_id
      sounds = Sound.joins("left join observation_sounds os on (sounds.id=os.sound_id)").
        where("os.id IS NULL").
        where("sounds.id BETWEEN ? AND ?", index, index + batch_size)
      sounds.each do |s|
        # set the orphan attribute on sound, which will set the same on Deletedsound
        s.orphan = true
        s.destroy
      end
      index += batch_size
    end
  end


  desc "Delete orphaned and expired photos"
  task :delete_orphaned_and_expired_photos => :environment do
    Rake::Task["inaturalist:delete_orphaned_photos"].invoke
    Rake::Task["inaturalist:delete_expired_photos"].invoke
  end

  desc "Delete orphaned and expired sounds"
  task :delete_orphaned_and_expired_sounds => :environment do
    Rake::Task["inaturalist:delete_orphaned_sounds"].invoke
    Rake::Task["inaturalist:delete_expired_sounds"].invoke
  end

  desc "Find all javascript i18n keys and print a new translations.js"
  task :generate_translations_js => :environment do
    output_path = "app/assets/javascripts/i18n/translations.js"
    # various keys from models, or from JS dynamic calls
    all_keys = [
      "added!",
      "amphibians",
      "animals",
      "arachnids",
      "asc",
      "birds",
      "black",
      "blue",
      "brown",
      "browse",
      "casual",
      "checklist",
      "colors",
      "copyright",
      "data_quality",
      "date.formats.month_day_year",
      "date_added",
      "date_format.month",
      "date_picker",
      "desc",
      "edit_license",
      "endemic",
      "exporting",
      "find",
      "find",
      "flowering_phenology",
      "frequency",
      "fungi",
      "green",
      "grey",
      "imperiled",
      "input_taxon",
      "insect_life_stage",
      "insects",
      "introduced",
      "kml_file_size_error",
      "lexicons",
      "lexicons",
      "loading",
      "mammals",
      "maps",
      "maptype_for_places",
      "misidentifications",
      "mollusks",
      "momentjs",
      "native",
      "none",
      "number_selected",
      "observation_date",
      "orange",
      "output_taxon",
      "pink",
      "place_geo.geo_planet_place_types",
      "places_name",
      "places_name",
      "plants",
      "preview",
      "protozoans",
      "purple",
      "random",
      "ranks",
      "ray_finned_fishes",
      "red",
      "reload_timed_out",
      "reptiles",
      "research",
      "rg_observations",
      "saving",
      "something_went_wrong_adding",
      "status_globally",
      "status_in_place",
      "supporting",
      "taxon_drop",
      "taxon_merge",
      "taxon_split",
      "taxon_stage",
      "taxon_swap",
      "unknown",
      "view_more",
      "views.observations.export.taking_a_while",
      "views.taxa.show.frequency",
      "white",
      "vulnerable",
      "yellow",
      "you_are_setting_this_project_to_aggregate"
    ]
    %w(
      all_rank_added_to_the_database
      all_taxa
      controlled_term_labels
      establishment
    ).each do |key|
      all_keys += I18n.t( key ).map{|k,v| "#{key}.#{k}" }
    end
    all_keys += ControlledTerm.attributes.map{|a|
      a.values.map{|v| "add_#{a.label.parameterize.underscore}_#{v.label.underscore}_annotation" }
    }.flatten
    # look for other keys in all javascript files
    scanner_proc = Proc.new do |f|
      # Ignore non-files
      next unless File.file?( f )
      # Ignore images and php scripts
      next if f =~ /\.(gif|png|php)$/
      # Ignore generated webpack outputs
      next if f =~ /\-webpack.js$/
      # Ignore an existing translations file
      next if f == output_path
      contents = IO.read( f )
      results = contents.scan(/(I18n|shared).t\(\s*(["'])(.*?)\2/i)
      unless results.empty?
        all_keys += results.map{ |r| r[2].chomp(".") }
      end
    end
    Dir.glob(Rails.root.join("app/assets/javascripts/**/*")).each(&scanner_proc)
    Dir.glob(Rails.root.join("app/webpack/**/*")).each(&scanner_proc)

    # look for keys in angular expressions in all templates
    Dir.glob(Rails.root.join("app/views/**/*")).each do |f|
      next unless File.file?( f )
      next if f =~ /\.(gif|png|php)$/
      next if f == output_path
      contents = IO.read( f )
      results = contents.scan(/\{\{.*?(I18n|shared).t\( ?(.)(.*?)\2.*?\}\}/i)
      unless results.empty?
        all_keys += results.map{ |r| r[2].chomp(".") }
      end
    end

    # remnant from a dynamic JS call for colors
    all_keys.delete("lts[i].valu")

    # load translations
    all_translations = { }
    I18n.backend.send(:init_translations)
    I18n.backend.send(:translations).keys.each do |locale|
      next if locale === :qqq
      all_translations[ locale ] = { }
      all_keys.uniq.sort.each do |key_string|
        split_keys = key_string.split(".").select{|k| k !~ /\#\{/ }.map(&:to_sym)
        split_keys.inject(all_translations[ locale ]) do |h, key|
          if key == split_keys.last
            value = split_keys.inject(I18n.backend.send(:translations)[locale], :[]) rescue nil
            if value
              h[key] ||= value
            elsif Rails.env.development?
              puts "WARNING: Failed to translate #{locale}.#{key}"
            end
          else
            h[key] ||= { }
          end
          h[key]
        end
      end
    end

    # output what should be the new contents of app/assets/javascripts/i18n/translations.js
    File.open(output_path, "w") do |file|
      file.puts "I18n.translations || (I18n.translations = {});"
      all_translations.sort.each do |locale, translastions|
        file.puts "I18n.translations[\"#{ locale }\"] = #{ JSON.pretty_generate( translastions ) };"
      end
    end
  end

  desc "Fetch missing image dimensions"
  task :fetch_image_dimensions => :environment do
    scope = LocalPhoto.where("original_url IS NOT NULL").
      where("metadata IS NULL OR metadata !~ 'dimensions: *\n *:orig'")
    batch_num = 0
    batch_size = 100
    total_batches = (scope.count / batch_size.to_f).ceil
    scope.find_in_batches(batch_size: batch_size) do |batch|
      batch_num += 1
      puts "batch #{ batch_num } of #{ total_batches }"
      batch.each do |photo|
        photo.metadata ||= { }
        photo.metadata[:dimensions] = photo.extrapolate_dimensions_from_original
        photo.update_column(:metadata, photo.metadata)
      end
    end
  end

  desc "Remove expired sessions"
  task :remove_expired_sessions => :environment do
    expiration_date = 30.days.ago
    ActiveRecord::SessionStore::Session.select(:id, :updated_at).find_in_batches(batch_size: 10000) do |batch|
      expired_ids = batch.select{ |s| s.updated_at < expiration_date }.map(&:id)
      ActiveRecord::SessionStore::Session.where(id: expired_ids).delete_all
    end
  end

end

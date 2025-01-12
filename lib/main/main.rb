module Main
  class Main
    def ag_scrape
      programs = Ag::Scraping.new.main
      programs.each do |p|
        Job.new(
          ch: Job::CH[:ag],
          title: p.title,
          start: p.start_time.next_on_air,
          end: p.start_time.next_on_air + p.minutes.minutes
        ).schedule
      end
    end

    def radiko_scrape
      channels = []
      channels += Settings.radiko_channels if Settings.radiko_channels
      channels += Settings.radiko_premium.channels if Settings.try(:radiko_premium).try(:channels)
      channels.each do |ch|
        programs = Radiko::Scraping.new.get(ch)
        programs.each do |p|
          title = p.title
          title += " #{p.performers}" if p.performers.present?
          Job.new(
            ch: ch,
            title: title.slice(0, 240),
            start: p.start_time,
            end: p.end_time
          ).schedule
        end
      end
    end

    def radiru_scrape
      unless Settings.radiru_channels
        exit 0
      end

      Settings.radiru_channels.each do |ch|
        programs = Radiru::Scraping.new.get(ch)
        programs.each do |p|
          Job.new(
            ch: ch,
            title: p.title,
            start: p.start_time,
            end: p.end_time
          ).schedule
        end
      end
    end

    def onsen_scrape
      program_list = Onsen::Scraping.new.main

      program_list.each do |program|
        if program.update_date.blank? || program.file_url.blank?
          next
        end
        ActiveRecord::Base.transaction do
          if OnsenProgram.where(file_url: program.file_url).first
            next
          end

          p = OnsenProgram.new
          p.title = program.title
          p.number = program.number
          p.date = program.update_date
          p.file_url = program.file_url
          p.personality = program.personality
          p.state = OnsenProgram::STATE[:waiting]
          p.retry_count = 0
          p.save
        end
      end
    end

    def hibiki_scrape
      program_list = Hibiki::Scraping.new.main

      program_list.each do |program|
        ActiveRecord::Base.transaction do
          if HibikiProgramV2
              .where(access_id: program.access_id)
              .where(episode_id: program.episode_id)
              .where(episode_type: program.episode_type)
              .first
            next
          end

          p = HibikiProgramV2.new
          p.access_id = program.access_id
          p.episode_id = program.episode_id
          p.episode_type = program.episode_type
          p.title = program.title
          p.episode_name = program.episode_name
          p.cast = program.cast
          p.state = HibikiProgramV2::STATE[:waiting]
          p.retry_count = 0
          p.save
        end
      end
    end

    def niconama_scrape
      if !Settings.niconico || !Settings.niconico.live
        exit 0
      end

      program_list = NiconicoLive::Scraping.new.main

      program_list.each do |program|
        ActiveRecord::Base.transaction do
          if NiconicoLiveProgram.where(id: program.id).first
            next
          end

          p = NiconicoLiveProgram.new
          p.id = program.id
          p.title = program.title
          p.state = NiconicoLiveProgram::STATE[:waiting]
          p.cannot_recovery = false
          p.memo = ''
          p.retry_count = 0
          p.save
        end
      end
    end

    def agonp_scrape
      unless Settings.agonp
        exit 0
      end

      program_list = Agonp::Scraping.new.main

      program_list.each do |program|
        ActiveRecord::Base.transaction do
          if AgonpProgram.where(episode_id: program.episode_id).first
            next
          end

          p = AgonpProgram.new
          p.title = program.title
          p.personality = program.personality
          p.episode_id = program.episode_id
          p.price = program.price
          p.state = OndemandRetry::STATE[:waiting]
          p.retry_count = 0
          p.save
        end
      end
    end

    def wikipedia_scrape
      unless Settings.niconico && Settings.niconico.live.keyword_wikipedia_categories
        exit 0
      end

      Settings.niconico.live.keyword_wikipedia_categories.each do |category|
        items = Wikipedia::Scraping.new.main(category)
        items = items.map do |item|
          [category, item]
        end
        WikipediaCategoryItem.import(
          [:category, :title],
          items,
          on_duplicate_key_update: [:title]
        )
      end
    end

    def nicodou_scrape
      if !Settings.niconico || !Settings.niconico.video
        exit 0
      end

      program_list = NiconicoVideo::Scraping.new.main

      program_list.each do |program|
        ActiveRecord::Base.transaction do
          if NiconicoVideoProgram.where(video_id: program.video_id).first
            next
          end

          p = NiconicoVideoProgram.new
          p.video_id = program.video_id
          p.title = program.title
          p.state = OndemandRetry::STATE[:waiting]
          p.retry_count = 0
          p.save
        end
      end
    end

    def rec_one
      jobs = nil
      ActiveRecord::Base.connection_pool.with_connection do
        ActiveRecord::Base.transaction do
          jobs = Job
            .where(
              "? <= `start` and `start` <= ?",
              2.minutes.ago,
              5.minutes.from_now
            )
            .where(state: Job::STATE[:scheduled])
            .order(:start)
            .lock
            .all
          if jobs.empty?
            return 0
          end
          jobs.each do |j|
            j.state = Job::STATE[:recording]
            j.save!
          end
        end
      end

      threads_from_records(jobs) do |j|
        Rails.logger.debug "rec thread created. job:#{j.id}"

        succeed = false
        if j.ch == Job::CH[:ag]
          succeed = Ag::Recording.new.record(j)
        elsif Settings.radiru_channels && Settings.radiru_channels.include?(j.ch)
          succeed = Radiru::Recording.new.record(j)
        else
          succeed = Radiko::Recording.new.record(j)
        end

        ActiveRecord::Base.connection_pool.with_connection do
          j.state =
            if succeed
              Job::STATE[:done]
            else
              Job::STATE[:failed]
            end
          j.save!
        end

        Rails.logger.debug "rec thread end. job:#{j.id}"
      end

      return 0
    end

    def rec_ondemand
      onsen_download
      hibiki_download
      agonp_download
    end

    LOCK_NICONAMA_DOWNLOAD = 'lock_niconama_download'
    def niconama_download
      unless Settings.niconico
        return 0
      end
      ActiveRecord::Base.transaction do
        l = KeyValue.where(key: LOCK_NICONAMA_DOWNLOAD).lock.first
        if !l
          l = KeyValue.new
          l.key = LOCK_NICONAMA_DOWNLOAD
          l.value = 'true'
          l.save!
        elsif l.value == 'false'
          l.value = 'true'
          l.save!
        elsif l.updated_at < 1.hours.ago
          l.touch
        else
          return 0
        end
      end

      p = nil
      ActiveRecord::Base.transaction do
        # ニコ生は検索オプションで「タイムシフト視聴可」を付けても
        # 実際にはまだタイムシフトが用意されていない場合がある
        # これに対応するため検索で発見しても一定時間待つ
        p = NiconicoLiveProgram
          .where(state: NiconicoLiveProgram::STATE[:waiting])
          .where('`created_at` <= ?', 2.hours.ago)
          .lock
          .first
        if p
          p.state = NiconicoLiveProgram::STATE[:downloading]
          p.save!
        end
      end

      if p
        NiconicoLive::Downloading.new.download(p)
        p.save!
      end

      ActiveRecord::Base.transaction do
        l = KeyValue.lock.find(LOCK_NICONAMA_DOWNLOAD)
        l.value = 'false'
        l.save!
      end

      return 0
    end

    private

    def threads_from_records(records)
      thread_array = []
      records.each do |record|
        thread_array << Thread.start(record) do |r|
          begin
            yield r
          rescue => e
            Rails.logger.error %W|#{e.class}\n#{e.inspect}\n#{e.backtrace.join("\n")}|
          end
        end
        sleep 1
      end

      thread_array.each do |th|
        th.join
      end
    end

    def onsen_download
      download(OnsenProgram, Onsen::Downloading.new)
    end

    def hibiki_download
      download2(HibikiProgramV2, Hibiki::Downloading.new)
    end

    def agonp_download
      unless Settings.agonp
        exit 0
      end
      download(AgonpProgram, Agonp::Downloading.new)
    end

    def download(model_klass, downloader)
      p = nil
      ActiveRecord::Base.transaction do
        p = fetch_downloadable_program(model_klass)
        unless p
          return 0
        end

        p.state = model_klass::STATE[:downloading]
        p.save!
      end

      download_(model_klass, downloader, p)

      return 0
    end

    def download2(model_klass, downloader)
      p = nil
      ActiveRecord::Base.transaction do
        # Hibikiで古いデータのキャッシュが残っているのかepisode_idが一致せず
        # outdatedと誤判定してしまうケースがあった
        # 対策として時間を置くことでprograms APIと各個別program APIのepisode_idが一致すること狙う
        p = fetch_downloadable_program(model_klass, 30.minutes.ago)
        unless p
          return 0
        end

        p.state = model_klass::STATE[:downloading]
        p.save!
      end

      download_(model_klass, downloader, p)

      return 0
    end

    def download_(klass, downloader, p)
      succeed = false
      begin
        succeed = downloader.download(p)
      rescue => e
        Rails.logger.error %W|#{e.class}\n#{e.inspect}\n#{e.backtrace.join("\n")}|
      end
      if p.state == klass::STATE[:downloading]
        p.state =
          if succeed
            klass::STATE[:done]
          else
            klass::STATE[:failed]
          end
      end
      unless succeed
        p.retry_count += 1
        if p.retry_count > klass::RETRY_LIMIT
          Rails.logger.error "#{klass.name} rec failed. exceeded retry_limit. #{p.id}: #{p.title}"
        end
      end
      p.save!
    end

    def fetch_downloadable_program(klass, older_than = nil)
      p = klass
        .where(state: klass::STATE[:waiting])
      if older_than
        p = p.where('`created_at` <= ?', older_than)
      end
      p = p
        .lock
        .first
      return p if p

      klass
        .where(state: [
               klass::STATE[:failed],
               klass::STATE[:downloading],
        ])
        .where('`retry_count` <= ?', klass::RETRY_LIMIT)
        .where('`updated_at` <= ?', 1.day.ago)
        .lock
        .first
    end
  end
end

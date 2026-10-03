# frozen_string_literal: true

# Загрузка ГАР из Rails-приложения фоновой задачей (Т12): скачать архив, импортировать два
# субъекта, построить пути и переключить схему — с прогрессом на пульте админки.
#
#   GarImportJob.perform_later(BackgroundRun.create!(kind: "gar_import").id, %w[43 11])
#
# BackgroundRun — модель прогона приложения (статус, этап, прогресс, отчёт); здесь от неё нужны
# update! и колонки stage, done, total, status, error, report. Шаги идемпотентны: если задача
# упала или её перезапустили, повторный запуск пропустит уже сделанное (скачанный архив,
# загруженную схему, заполненные пути). Второй одновременный запуск получит Gar::LockedError —
# задача сообщает об этом и не повторяется. Соединения с базой ГАР открывает каждый шаг сам,
# внутри задачи: ничего не открывается до fork воркера.

class GarImportJob < ApplicationJob
  queue_as :gar

  # Прогресс пишется не чаще раза в PROGRESS_INTERVAL секунд: импорт сообщает о каждом файле,
  # пути — о каждом батче
  PROGRESS_INTERVAL = 2

  def perform(run_id, region_codes)
    run = BackgroundRun.find(run_id)
    run.update!(status: "running", started_at: Time.current)
    progress = progress_reporter(run)

    zip    = Gar.download(region_codes:, on_progress: progress) # только файлы этих субъектов (~300 МБ на два)
    schema = Gar.import(zip, region_codes:, on_progress: progress)
    Gar.build_paths(schema, on_progress: progress)
    Gar.switch(schema, on_progress: progress)
    removed = Gar.cleanup_schemas

    # Отчёт — gar_meta текущей схемы: версия, дата выгрузки, субъекты, таблицы, время стадий
    run.update!(status: "done", finished_at: Time.current, report: Gar.current_version.as_json.merge("removed_schemas" => removed))
  rescue Gar::LockedError => e
    run&.update!(status: "skipped", error: e.message) # базу уже обновляет другой прогон
  rescue Gar::Error => e
    run&.update!(status: "failed", error: "#{e.class}: #{e.message}", finished_at: Time.current)
    raise
  end

  private

  # ->(done, total, stage): stage — :download (байты), :import (байты XML), :indexes (таблицы),
  # :paths (записи), :switch; total у загрузки — nil, если сервер не сообщил размер. При
  # параллельном импорте в потоках прогресс приходит из потоков импорта (по одному), поэтому
  # запись — через with_connection
  def progress_reporter(run)
    reported = nil
    lambda do |done, total, stage|
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      next if reported && now - reported < PROGRESS_INTERVAL && done != total

      reported = now
      ActiveRecord::Base.connection_pool.with_connection do
        run.update_columns(stage: stage.to_s, done:, total:, updated_at: Time.current)
      end
    end
  end
end

# frozen_string_literal: true

module Gar
  # Схемы ГАР в базе: текущая (config.database_schema, «gar»), загруженные импортом
  # <текущая>_v<версия> и резервные <текущая>_backup_v<версия>. Переключение и замена —
  # переименованиями в одной транзакции: читатели видят либо прежнюю схему, либо новую.
  # Текущая схема не удаляется никогда: при переключении она становится резервной.
  module Schemas
    class << self
      def exists?(conn, name) = conn.exec_params("SELECT 1 FROM pg_namespace WHERE nspname = $1", [name]).ntuples.positive?

      # Делает schema текущей (current); прежняя текущая становится резервной. Затем удаляет
      # резервные сверх keep_backups — самые старые по версии. Возвращает удалённые схемы
      def switch(conn, schema, current:, keep_backups:)
        backup = backup_name(conn, current) if exists?(conn, current)
        replace(conn, schema, current, backup:)
        Gar.logger.info "Схема #{schema} стала текущей (#{current})#{", прежняя — #{backup}" if backup}"
        drop(conn, backups(conn, current).drop(keep_backups))
      end

      # Удаляет резервные схемы сверх keep_backups и схемы импорта, которые уже не станут
      # текущими (stale_imports). Возвращает удалённые
      def cleanup(conn, current, keep_backups:)
        drop(conn, backups(conn, current).drop(keep_backups) + stale_imports(conn, current))
      end

      # Заменяет target схемой source в одной транзакции: прежняя target переименовывается в
      # backup (target должна существовать) или, без него, удаляется. Блок выполняется в той же транзакции
      def replace(conn, source, target, backup: nil)
        conn.transaction do
          conn.exec("DROP SCHEMA IF EXISTS #{quote(backup || target)} CASCADE")
          conn.exec("ALTER SCHEMA #{quote(target)} RENAME TO #{quote(backup)}") if backup
          conn.exec("ALTER SCHEMA #{quote(source)} RENAME TO #{quote(target)}")
          yield conn if block_given?
        end
      end

      # Резервные схемы текущей current, новые первыми
      def backups(conn, current)
        names_with_prefix(conn, "#{current}_backup_").sort_by { |name| [Meta.read(conn, name)&.version_id || 0, name] }.reverse
      end

      # Имя схемы импорта версии version_id
      def import_name(current, version_id) = "#{current}_v#{version_id}"

      # Схемы импорта текущей current (<текущая>_v<версия>), по имени
      def imports(conn, current) = names_with_prefix(conn, "#{current}_v").grep(/\A#{Regexp.escape(current)}_v\d+\z/).sort

      # Схемы импорта (<текущая>_v<версия>) не новее текущей и незавершённые: их уже не
      # переключат. Без gar_meta у текущей — только незавершённые
      def stale_imports(conn, current)
        version = Meta.read(conn, current)&.version_id
        imports(conn, current).select do |name|
          meta = Meta.read(conn, name)
          meta && (meta.status == "importing" || (version && meta.version_id <= version))
        end
      end

      # Место на диске под таблицы схемы с индексами и TOAST, байт
      def size(conn, name)
        conn.exec_params("SELECT COALESCE(sum(pg_total_relation_size(c.oid)), 0) FROM pg_class c " \
                         "JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = $1 AND c.relkind IN ('r', 'm')", [name]).getvalue(0, 0).to_i
      end

      # Удаляет схемы names и возвращает их
      def drop(conn, names)
        names.each do |name|
          conn.exec("DROP SCHEMA #{quote(name)} CASCADE")
          Gar.logger.info "Удалена схема #{name}"
        end
      end

      private

      # Имя резервной схемы — по версии из gar_meta, без неё — по времени
      def backup_name(conn, current)
        version = Meta.read(conn, current)&.version_id
        "#{current}_backup_#{version ? "v#{version}" : Time.now.strftime('%Y%m%d_%H%M%S')}"
      end

      def names_with_prefix(conn, prefix)
        conn.exec_params("SELECT nspname FROM pg_namespace WHERE starts_with(nspname, $1)", [prefix]).column_values(0)
      end

      def quote(name) = Schema.quote(name)
    end
  end
end

# frozen_string_literal: true

# Обновление ГАР по расписанию (Т13): дельты новее загруженной версии или, если цепочка
# дельт прервана, полный импорт — одной фоновой задачей.
#
# Расписание Solid Queue (config/recurring.yml) — по вторникам и пятницам, когда ФНС
# публикует выгрузки:
#
#   production:
#     gar_update:
#       class: GarUpdateJob
#       queue: gar
#       schedule: every tuesday and friday at 6am
#
# Регионы полного импорта — config.region_codes в инициализаторе (дельты берут субъекты из
# gar_meta загруженной схемы). Пока идёт обновление, поиск работает: дельта меняет текущую
# схему в одной транзакции, полный импорт идёт в новую схему. Второй запуск получает
# Gar::LockedError — задача его пропускает: обновление уже идёт.

class GarUpdateJob < ApplicationJob
  queue_as :gar

  def perform
    result = Gar.update!
    case result.kind
    when :none  then Rails.logger.info "ГАР: уже последняя версия #{result.to_version}"
    when :delta then Rails.logger.info "ГАР: применены дельты #{result.versions.join(', ')}"
    when :full  then Rails.logger.info "ГАР: загружена выгрузка #{result.to_version} (полный импорт)"
    end
  rescue Gar::LockedError => e
    Rails.logger.info "ГАР: обновление пропущено — #{e.message}"
  end
end

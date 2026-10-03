# frozen_string_literal: true

require "yaml"

module Gar
  # Группы равнозначных слов поиска из трёх источников:
  # - справочники типов ГАР в схеме (краткое ↔ полное имя: «ул» ↔ «улица», «к.» ↔ «корпус»);
  # - встроенный словарь lib/gar/data/synonyms.yml (config.builtin_synonyms = false отключает);
  # - config.synonyms приложения: { "проспект" => %w[пркт] }.
  #
  # Запрос разворачивается в tsquery: каждое слово — OR всех вариантов его групп, слова — AND.
  # Индекс синонимов не содержит, поэтому новые синонимы работают без перестроения путей.
  # Справочники читаются из базы раз в TTL на схему и настройки; Synonyms.reset! сбрасывает кэш.
  class Synonyms
    BUILTIN = File.expand_path("data/synonyms.yml", __dir__)
    # Справочники типов: краткое и полное имя
    DICTIONARIES = [:address_object_types, :house_types, :add_house_types].freeze

    # Сколько секунд живёт кэш справочников: после переключения схемы другие процессы
    # подхватят новые типы не позже этого срока
    TTL = 600

    @cache = {}
    @lock  = Mutex.new

    class << self
      # Синонимы схемы с текущими настройками; кэш — по схеме и настройкам синонимов.
      # Соединение (db_conn или из пула) берётся, только если в кэше их нет
      def for(schema, db_conn = nil)
        config = Gar.configuration
        key    = [schema, config.builtin_synonyms, config.synonyms]
        now    = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        cached = @lock.synchronize { @cache[key] }
        return cached.last if cached && now - cached.first <= TTL

        synonyms = Database.with_connection(db_conn) { |conn| load(conn, schema, config) }
        @lock.synchronize { @cache[key] = [now, synonyms] }
        synonyms
      end

      def reset!
        @lock.synchronize { @cache.clear }
      end

      def builtin = @builtin ||= YAML.safe_load_file(BUILTIN).map { |group| group.map { normalize(_1) }.freeze }.freeze

      # Строка запроса → слова: нижний регистр, ё → е, точки и знаки препинания — разделители;
      # дефис и дробь остаются внутри слова («пр-кт», «10/2»)
      def words(text) = text.to_s.downcase.tr("ё", "е").gsub(%r{[^[:alnum:]\-/]+}, " ").split

      def normalize(word) = words(word).join(" ")

      private

      # Группы справочников и встроенного словаря; типы адресных объектов — слова справочника
      # address_object_types; стоп-слова словаря russian среди вариантов («к», «с»): их нет в индексе
      def load(conn, schema, config)
        dictionaries = dictionary_pairs(conn, schema)
        groups       = [*dictionaries.values.flatten(1).select { _1.size > 1 }, *(builtin if config.builtin_synonyms)]
        words        = [*groups.flatten, *config.synonyms.to_a.flatten].map { normalize(_1) }.uniq.reject { _1.include?(" ") }
        stop         = conn.exec_params("SELECT w FROM unnest($1::text[]) w WHERE to_tsvector('russian', w) = ''::tsvector",
                                        [Database.array(words)]).column_values(0)
        new(groups, stopwords: stop, extensions: config.synonyms, types: dictionaries.fetch(:address_object_types, []).flatten)
      end

      # Пары «краткое и полное имя» справочников типов схемы: { таблица => [[слово, …], …] }
      def dictionary_pairs(conn, schema)
        tables = DICTIONARIES.to_h { [Schema.fetch(_1).qualified_name(schema), _1] }
        Database.existing_relations(conn, tables.keys).to_h do |table|
          pairs = conn.exec("SELECT DISTINCT short_name, name FROM #{table}").values.map { |pair| pair.compact.map { normalize(_1) }.uniq }
          [tables.fetch(table), pairs]
        end
      end
    end

    # groups — группы равнозначных слов; extensions — слово → свои варианты (config.synonyms):
    # варианты получают все группы слова. stopwords — варианты, которых нет в индексе: слово
    # с таким вариантом в запрос не идёт. types — имена типов адресных объектов («ул», «р-н»)
    def initialize(groups, stopwords: [], extensions: {}, types: [])
      @stopwords = stopwords.to_set
      @types     = types.reject { _1.include?(" ") }.to_set
      @variants  = {}
      groups.each { add(_1) }
      extensions.each { |word, variants| add([*variants(self.class.normalize(word)), *variants]) }
      @variants.freeze
    end

    # Варианты слова (само слово первым)
    def variants(word) = [word, *@variants.fetch(word, [])].uniq

    # Слова без типов адресных объектов: тип элемента, которого нет в пути («Нововятский р-н»
    # при пути «…, Киров г, Советская (Нововятский) ул»), не должен обнулять поиск
    def without_types(words) = words.reject { @types.include?(_1) }

    # tsquery для to_tsquery('russian', …) или nil, если слов нет. prefix — последнее слово
    # вводится: оно ищется как префикс, а его синонимы — целиком. Слово, у которого среди
    # вариантов есть стоп-слово («к» — «корпус»), пропускается: в индексе «к» нет, и требовать
    # «корпус» нельзя
    def tsquery(words, prefix: false)
      groups =
        words.each_with_index.filter_map do |word, index|
          variants = variants(word)
          next if variants.size > 1 && variants.any? { @stopwords.include?(_1) }

          typed = prefix && index == words.size - 1
          "(#{variants.map { |variant| lexemes(variant, typed && variant == word) }.join(' | ')})"
        end
      groups.join(" & ") unless groups.empty?
    end

    private

    def add(group)
      words = group.map { self.class.normalize(_1) }.reject(&:empty?)
      words.each { |word| @variants[word] = @variants.fetch(word, []) | words }
    end

    # Вариант из нескольких слов — фраза; лексемы в кавычках, слово уже без кавычек и операторов
    def lexemes(variant, prefix)
      variant.split.map { "'#{_1}'#{':*' if prefix}" }.join(" <-> ")
    end
  end
end

# frozen_string_literal: true

module Routing
  module Constraints
    # Фильтр по банку получателя.
    #
    # Поле `banks` само по себе не говорит, белый это список или чёрный —
    # смысл ему задаёт `exclude_banks`. В данных кейса это булев флаг
    # (`false` — список разрешённых), в тексте ТЗ — отдельный список
    # исключений. Мы принимаем оба прочтения и объединяем их: явные
    # исключения запрещают всегда, а `banks` работает как чёрный список
    # только при поднятом флаге.
    #
    # Пустой `banks` без исключений означает «работаем со всеми банками» —
    # именно так задан quickpay, и трактовать это как «ни одного банка»
    # значило бы выключить единственного универсального провайдера.
    #
    # Написание банка сравнивается двумя способами, и выбор между ними —
    # настройка `spelling`:
    #
    #   as_is     — дословно, как в данных. Ровно так читает списки скрипт
    #               автопроверки; в конфигурации этого кейса стоит именно оно,
    #               потому что расходиться с проверяющим дороже, чем не узнать
    #               «SBERBANK».
    #   normalize — с приведением к общему виду (регистр, пробелы, кавычки,
    #               правовая форма) и таблицей синонимов. Значение по умолчанию:
    #               на чужих данных, где написания не выверены, оно спасает
    #               больше заявок, чем теряет.
    #
    # Расхождение между режимами нашёл обстрел случайными очередями
    # (`tools/fuzz.rb`): банк «SBERBANK» в заявке — единственный вход, на
    # котором наш выбор и модель проверяющего расходились.
    class BankFilter < Base
      def check(context)
        provider = context.provider
        literal = setting("spelling", "normalize") == "as_is"
        blacklist, whitelist = lists_for(provider, literal)
        return skip if blacklist.empty? && whitelist.empty?

        bank = literal ? context.operation.bank : context.operation.bank_key
        if bank.nil? || bank.empty?
          return nil if whitelist.empty? || setting("unknown_bank_policy", "allow") == "allow"

          return violation("bank_unknown",
                           "банк заявки не указан, а провайдер работает по списку из " \
                           "#{whitelist.size} банков")
        end

        if blacklist.include?(bank)
          return violation("bank_excluded",
                           "#{context.operation.bank} в списке исключений (#{blacklist.join(', ')})")
        end

        if !whitelist.empty? && !whitelist.include?(bank)
          return violation("bank_not_in_list",
                           "#{context.operation.bank} не входит в banks (#{whitelist.join(', ')})")
        end

        nil
      end

      private

      def lists_for(provider, literal)
        allowed = literal ? provider.banks_literal : provider.banks
        excluded = literal ? provider.exclude_banks_literal : provider.exclude_banks
        return [(excluded + allowed).uniq, []] if provider.banks_are_blacklist

        [excluded, allowed]
      end
    end
  end
end

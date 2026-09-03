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
    class BankFilter < Base
      def check(context)
        provider = context.provider
        blacklist, whitelist = lists_for(provider)
        return skip if blacklist.empty? && whitelist.empty?

        bank = context.operation.bank_key
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

      def lists_for(provider)
        return [(provider.exclude_banks + provider.banks).uniq, []] if provider.banks_are_blacklist

        [provider.exclude_banks, provider.banks]
      end
    end
  end
end

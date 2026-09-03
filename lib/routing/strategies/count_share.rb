# frozen_string_literal: true

module Routing
  module Strategies
    # Стратегия 1: распределение по доле от количества заявок.
    #
    # Наивный способ — бросать кубик с вероятностями долей — на десяти заявках
    # даёт отклонение в десятки процентов. Мы вместо этого считаем дефицит:
    # сколько заявок провайдер уже должен был получить к этому моменту
    # (target * (N+1)) и сколько получил на самом деле. Кто отстал сильнее —
    # тот и предпочтительнее. Это детерминированный аналог метода наибольших
    # остатков, разложенный на поток: доли сходятся к целевым с первых же заявок.
    class CountShare < Base
      def raw_score(context)
        target = context.fleet.count_target(context.provider.id, among: context.pool)
        return nil if target.zero?

        expected = target * (context.fleet.total_selected_count + 1)
        expected - context.state.selected_count
      end

      def explain(context)
        target = context.fleet.count_target(context.provider.id, among: context.pool)
        actual = context.fleet.actual_count_share(context.provider.id)
        deficit = raw_score(context)
        return "целевая доля по количеству не задана" if deficit.nil?

        "доля по количеству #{pct(actual)}% при цели #{pct(target)}% " \
          "(#{context.state.selected_count} из #{context.fleet.total_selected_count}), " \
          "недобор #{deficit.round(2)} заявки"
      end
    end
  end
end

class Loan::PaymentSplitter
  Split = Struct.new(
    :matched,
    :period_number,
    :due_date,
    :interest,
    :principal,
    :extra_principal,
    :variance,
    :scheduled_payment,
    keyword_init: true
  ) do
    def matched?
      matched
    end
  end

  DEFAULT_DATE_WINDOW = 7

  def initialize(loan, date_window: DEFAULT_DATE_WINDOW)
    @loan = loan
    @date_window = date_window
  end

  def split(payment_date:, amount:, paid_period_numbers: nil, period_number: nil)
    paid_period_numbers ||= loan.paid_annuity_period_numbers
    row = if period_number.present?
      unpaid_row_for_period(period_number, paid_period_numbers.map(&:to_i))
    else
      nearest_unpaid_row(payment_date, paid_period_numbers.map(&:to_i))
    end
    return unmatched(amount) unless row

    payment_amount = amount.to_d.abs
    return unmatched(amount) if period_number.blank? && payment_amount < row.scheduled_payment

    remaining_payment = payment_amount
    interest = [ remaining_payment, row.interest ].min
    remaining_payment -= interest

    principal = [ remaining_payment, row.scheduled_principal ].min
    remaining_payment -= principal

    extra_principal = [ remaining_payment, BigDecimal("0") ].max
    variance = row.scheduled_payment - payment_amount
    variance = BigDecimal("0") if variance.negative?

    Split.new(
      matched: true,
      period_number: row.period_number,
      due_date: row.due_date,
      interest: interest,
      principal: principal,
      extra_principal: extra_principal,
      variance: variance,
      scheduled_payment: row.scheduled_payment
    )
  end

  private
    attr_reader :loan, :date_window

    def nearest_unpaid_row(payment_date, paid_period_numbers)
      loan.amortization_schedule(as_of: payment_date).rows
        .reject { |row| paid_period_numbers.include?(row.period_number) }
        .select { |row| (row.due_date - payment_date).abs <= date_window.to_i }
        .min_by { |row| (row.due_date - payment_date).abs }
    end

    def unpaid_row_for_period(period_number, paid_period_numbers)
      period_number = period_number.to_i
      return nil if period_number <= 0 || paid_period_numbers.include?(period_number)

      loan.amortization_schedule.rows.find { |row| row.period_number == period_number }
    end

    def unmatched(amount)
      Split.new(
        matched: false,
        period_number: nil,
        due_date: nil,
        interest: BigDecimal("0"),
        principal: BigDecimal("0"),
        extra_principal: BigDecimal("0"),
        variance: amount.to_d.abs,
        scheduled_payment: nil
      )
    end
end

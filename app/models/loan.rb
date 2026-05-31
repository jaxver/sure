class Loan < ApplicationRecord
  include Accountable

  SUBTYPES = {
    "mortgage" => { short: "Mortgage", long: "Mortgage" },
    "student" => { short: "Student Loan", long: "Student Loan" },
    "auto" => { short: "Auto Loan", long: "Auto Loan" },
    "other" => { short: "Other Loan", long: "Other Loan" }
  }.freeze

  validates :subtype, inclusion: { in: SUBTYPES.keys }, allow_blank: true
  validates :payment_cadence, inclusion: { in: %w[monthly] }, if: :annuity_enabled?
  validates :started_on, presence: true, if: :annuity_enabled?
  validates :initial_balance, numericality: { greater_than: 0 }, if: :annuity_enabled?
  validates :term_months, numericality: { only_integer: true, greater_than: 0 }, if: :annuity_enabled?
  validate :annuity_rate_periods_present
  validate :annuity_rate_period_start_dates_unique
  validates_associated :loan_rate_periods, if: :annuity_enabled?

  has_many :loan_rate_periods, dependent: :destroy
  accepts_nested_attributes_for :loan_rate_periods, allow_destroy: true, reject_if: :all_blank

  def monthly_payment
    if annuity_enabled?
      payment = amortization_schedule.current_scheduled_payment
      return payment && Money.new(payment, account.currency)
    end

    return nil if term_months.nil? || interest_rate.nil? || rate_type.nil? || rate_type != "fixed"
    return Money.new(0, account.currency) if account.loan.original_balance.amount.zero? || term_months.zero?

    annual_rate = interest_rate / 100.0
    monthly_rate = annual_rate / 12.0

    if monthly_rate.zero?
      payment = account.loan.original_balance.amount / term_months
    else
      payment = (account.loan.original_balance.amount * monthly_rate * (1 + monthly_rate)**term_months) / ((1 + monthly_rate)**term_months - 1)
    end

    Money.new(payment.round, account.currency)
  end

  def original_balance
    amount = annuity_enabled? && initial_balance.present? ? initial_balance : account.first_valuation_amount
    Money.new(amount, account.currency)
  end

  def amortization_schedule(as_of: Date.current)
    Loan::AmortizationSchedule.new(
      self,
      as_of: as_of,
      extra_principal_by_period: annuity_extra_principal_by_period
    )
  end

  def annuity_summary(as_of: Date.current)
    schedule = amortization_schedule(as_of: as_of)

    {
      scheduled_balance: schedule.scheduled_balance,
      balance_variance: schedule.balance_variance,
      current_rate_period: schedule.current_rate_period,
      current_scheduled_payment: schedule.current_scheduled_payment,
      remaining_periods: schedule.remaining_periods,
      total_interest: schedule.total_interest,
      payoff_date: schedule.payoff_date,
      recent_rows: schedule.paid_rows.last(3),
      upcoming_rows: schedule.upcoming_rows(limit: 3)
    }
  end

  def paid_annuity_period_numbers
    return [] unless account

    account.transactions.filter_map do |transaction|
      split = annuity_payment_split_extra(transaction)
      next unless split_current_for_schedule?(split)
      next if annuity_split_variance(split).positive?

      split["period_number"].to_i
    end
  end

  def annuity_extra_principal_by_period
    return {} unless account

    account.transactions.each_with_object(Hash.new(BigDecimal("0"))) do |transaction, result|
      split = annuity_payment_split_extra(transaction)
      next unless split_current_for_schedule?(split)

      period_number = split["period_number"].to_i
      extra_principal = split["extra_principal"].to_s.to_d
      result[period_number] += extra_principal if extra_principal.positive?
    end
  end

  def annuity_due_date_for_period(period_number)
    period_number = period_number.to_i
    return nil if period_number <= 0
    return nil if first_annuity_payment_on.blank?

    first_annuity_payment_on.advance(months: period_number - 1)
  end

  def first_annuity_payment_on
    first_payment_on.presence || started_on&.advance(months: 1)
  end

  class << self
    def color
      "#D444F1"
    end

    def icon
      "hand-coins"
    end

    def classification
      "liability"
    end
  end

  private
    def active_loan_rate_periods
      loan_rate_periods.reject(&:marked_for_destruction?)
    end

    def annuity_rate_periods_present
      return unless annuity_enabled?
      return if active_loan_rate_periods.any?

      errors.add(:loan_rate_periods, "must include at least one rate period")
    end

    def annuity_rate_period_start_dates_unique
      return unless annuity_enabled?

      starts = active_loan_rate_periods.filter_map(&:starts_on)
      errors.add(:loan_rate_periods, "cannot have duplicate start dates") if starts.uniq.size != starts.size
    end

    def annuity_payment_split_extra(transaction)
      split = transaction.extra&.fetch("loan_payment_split", nil)
      split if split.is_a?(Hash)
    end

    def split_current_for_schedule?(split)
      return false unless split

      period_number = split["period_number"].to_i
      expected_due_date = annuity_due_date_for_period(period_number)
      return false unless expected_due_date

      stored_due_date = parse_annuity_split_due_date(split["due_date"])
      return false if stored_due_date && stored_due_date != expected_due_date

      true
    end

    def parse_annuity_split_due_date(value)
      return nil if value.blank?

      Date.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def annuity_split_variance(split)
      split["variance"].to_s.to_d
    end

end

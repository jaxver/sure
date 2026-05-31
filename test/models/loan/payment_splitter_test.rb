require "test_helper"

class Loan::PaymentSplitterTest < ActiveSupport::TestCase
  setup do
    loan = Loan.new(
      annuity_enabled: true,
      started_on: Date.new(2024, 1, 1),
      payment_cadence: "monthly",
      initial_balance: 300000,
      term_months: 360,
      rate_type: "fixed"
    )
    loan.loan_rate_periods.build(starts_on: Date.new(2024, 1, 1), annual_rate: 6.0)
    @account = Account.create!(
      family: families(:dylan_family),
      name: "Annuity Mortgage",
      balance: 300000,
      currency: "USD",
      accountable: loan
    )
  end

  test "splits scheduled payment into interest and principal" do
    split = Loan::PaymentSplitter.new(@account.loan).split(
      payment_date: Date.new(2024, 2, 1),
      amount: 1798.65
    )

    assert split.matched?
    assert_equal 1, split.period_number
    assert_in_delta 1500, split.interest, 0.01
    assert_in_delta 298.65, split.principal, 0.01
    assert_in_delta 0, split.extra_principal, 0.01
    assert_in_delta 0, split.variance, 0.01
  end

  test "uses absolute amount when matching signed payment values" do
    split = Loan::PaymentSplitter.new(@account.loan).split(
      payment_date: Date.new(2024, 2, 1),
      amount: -1798.65
    )

    assert split.matched?
    assert_equal 1, split.period_number
    assert_in_delta 1500, split.interest, 0.01
    assert_in_delta 298.65, split.principal, 0.01
    assert_in_delta 0, split.variance, 0.01
  end

  test "matches exact payment dates from explicit first payment date" do
    loan = Loan.new(
      annuity_enabled: true,
      started_on: Date.new(2024, 12, 28),
      first_payment_on: Date.new(2025, 1, 28),
      payment_cadence: "monthly",
      initial_balance: 453407,
      term_months: 360,
      rate_type: "fixed"
    )
    loan.loan_rate_periods.build(starts_on: Date.new(2024, 12, 28), annual_rate: 3.65, payment_amount: 2074.15)
    account = Account.create!(
      family: families(:dylan_family),
      name: "Exact Date Mortgage",
      balance: 453407,
      currency: "EUR",
      accountable: loan
    )

    first_split = Loan::PaymentSplitter.new(account.loan).split(
      payment_date: Date.new(2025, 1, 28),
      amount: -2074.15
    )
    march_split = Loan::PaymentSplitter.new(account.loan).split(
      payment_date: Date.new(2025, 3, 28),
      amount: -2074.15,
      paid_period_numbers: [ 1 ]
    )

    assert first_split.matched?
    assert_equal 1, first_split.period_number
    assert_equal Date.new(2025, 1, 28), first_split.due_date
    assert march_split.matched?
    assert_equal 3, march_split.period_number
    assert_equal Date.new(2025, 3, 28), march_split.due_date
  end

  test "matches payments from explicit first payment date before loan start" do
    loan = Loan.new(
      annuity_enabled: true,
      started_on: Date.new(2025, 6, 1),
      first_payment_on: Date.new(2025, 1, 28),
      payment_cadence: "monthly",
      initial_balance: 453407,
      term_months: 360,
      rate_type: "fixed"
    )
    loan.loan_rate_periods.build(starts_on: Date.new(2025, 6, 1), annual_rate: 3.65, payment_amount: 2074.15)
    account = Account.create!(
      family: families(:dylan_family),
      name: "Backdated First Payment Mortgage",
      balance: 453407,
      currency: "EUR",
      accountable: loan
    )

    first_split = Loan::PaymentSplitter.new(account.loan).split(
      payment_date: Date.new(2025, 1, 28),
      amount: -2074.15
    )
    march_split = Loan::PaymentSplitter.new(account.loan).split(
      payment_date: Date.new(2025, 3, 28),
      amount: -2074.15,
      paid_period_numbers: [ 1 ]
    )

    assert first_split.matched?
    assert_equal 1, first_split.period_number
    assert_equal Date.new(2025, 1, 28), first_split.due_date
    assert march_split.matched?
    assert_equal 3, march_split.period_number
    assert_equal Date.new(2025, 3, 28), march_split.due_date
  end

  test "treats payment above scheduled amount as extra principal" do
    split = Loan::PaymentSplitter.new(@account.loan).split(
      payment_date: Date.new(2024, 2, 1),
      amount: 2000
    )

    assert split.matched?
    assert_in_delta 1500, split.interest, 0.01
    assert_in_delta 298.65, split.principal, 0.01
    assert_in_delta 201.35, split.extra_principal, 0.01
    assert_in_delta 0, split.variance, 0.01
  end

  test "does not automatically match underpayment to a scheduled period" do
    split = Loan::PaymentSplitter.new(@account.loan).split(
      payment_date: Date.new(2024, 2, 1),
      amount: 1000
    )

    assert_not split.matched?
    assert_in_delta 0, split.principal, 0.01
    assert_in_delta 0, split.extra_principal, 0.01
    assert_in_delta 1000, split.variance, 0.01
  end

  test "allows manual underpayment matching to an explicit period" do
    split = Loan::PaymentSplitter.new(@account.loan).split(
      payment_date: Date.new(2024, 2, 1),
      amount: 1000,
      period_number: 1
    )

    assert split.matched?
    assert_in_delta 1000, split.interest, 0.01
    assert_in_delta 0, split.principal, 0.01
    assert_in_delta 0, split.extra_principal, 0.01
    assert_in_delta 798.65, split.variance, 0.01
  end

  test "returns unmatched split when no schedule row is close enough" do
    split = Loan::PaymentSplitter.new(@account.loan).split(
      payment_date: Date.new(2024, 4, 20),
      amount: 1798.65,
      paid_period_numbers: [ 1, 2, 3 ]
    )

    assert_not split.matched?
    assert_nil split.period_number
    assert_in_delta 0, split.interest, 0.01
    assert_in_delta 0, split.principal, 0.01
    assert_in_delta 1798.65, split.variance, 0.01
  end

  test "matches explicit unpaid period outside the date window" do
    split = Loan::PaymentSplitter.new(@account.loan).split(
      payment_date: Date.new(2024, 4, 20),
      amount: 1798.65,
      period_number: 3
    )

    assert split.matched?
    assert_equal 3, split.period_number
    assert_equal Date.new(2024, 4, 1), split.due_date
    assert_in_delta 1497.00, split.interest, 0.01
    assert split.principal.positive?
  end

  test "does not match explicit period that is already paid" do
    split = Loan::PaymentSplitter.new(@account.loan).split(
      payment_date: Date.new(2024, 4, 20),
      amount: 1798.65,
      paid_period_numbers: [ 3 ],
      period_number: 3
    )

    assert_not split.matched?
  end

  test "skips schedule rows already recorded on loan transactions" do
    @account.entries.create!(
      amount: -298.65,
      currency: "USD",
      date: Date.new(2024, 2, 1),
      name: "Payment from Checking",
      entryable: Transaction.new(
        kind: "funds_movement",
        extra: {
          "loan_payment_split" => {
            "period_number" => 1
          }
        }
      )
    )

    split = Loan::PaymentSplitter.new(@account.loan).split(
      payment_date: Date.new(2024, 3, 1),
      amount: 1798.65
    )

    assert split.matched?
    assert_equal 2, split.period_number
  end

  test "recorded extra principal affects future split calculations" do
    @account.entries.create!(
      amount: -500,
      currency: "USD",
      date: Date.new(2024, 2, 1),
      name: "Payment from Checking",
      entryable: Transaction.new(
        kind: "funds_movement",
        extra: {
          "loan_payment_split" => {
            "period_number" => 1,
            "extra_principal" => "201.35"
          }
        }
      )
    )

    split = Loan::PaymentSplitter.new(@account.loan).split(
      payment_date: Date.new(2024, 3, 1),
      amount: 1798.65
    )

    assert split.matched?
    assert_equal 2, split.period_number
    assert_in_delta 1497.00, split.interest, 0.01
    assert_in_delta 301.65, split.principal, 0.01
  end
end

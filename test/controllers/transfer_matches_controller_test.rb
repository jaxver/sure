require "test_helper"

class TransferMatchesControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    ensure_tailwind_build
    sign_in @user = users(:family_admin)
  end

  test "matches existing transaction and creates transfer" do
    inflow_transaction = create_transaction(amount: 100, account: accounts(:depository))
    outflow_transaction = create_transaction(amount: -100, account: accounts(:investment))

    assert_difference "Transfer.count", 1 do
      post transaction_transfer_match_path(inflow_transaction), params: {
        transfer_match: {
          method: "existing",
          matched_entry_id: outflow_transaction.id
        }
      }
    end

    assert_redirected_to transactions_url
    assert_equal "Transfer created", flash[:notice]
  end

  test "creates transfer for target account" do
    inflow_transaction = create_transaction(amount: 100, account: accounts(:depository))

    assert_difference [ "Transfer.count", "Entry.count", "Transaction.count" ], 1 do
      post transaction_transfer_match_path(inflow_transaction), params: {
        transfer_match: {
          method: "new",
          target_account_id: accounts(:investment).id
        }
      }
    end

    assert_redirected_to transactions_url
    assert_equal "Transfer created", flash[:notice]
  end

  test "new transfer entry is protected from provider sync" do
    outflow_entry = create_transaction(amount: 100, account: accounts(:depository))

    post transaction_transfer_match_path(outflow_entry), params: {
      transfer_match: {
        method: "new",
        target_account_id: accounts(:investment).id
      }
    }

    transfer = Transfer.order(created_at: :desc).first
    new_entry = transfer.inflow_transaction.entry

    assert new_entry.user_modified?, "New transfer entry should be marked as user_modified to protect from provider sync"
  end

  test "assigns investment_contribution kind and category for investment destination" do
    # Outflow from depository (positive amount), target is investment
    outflow_entry = create_transaction(amount: 100, account: accounts(:depository))

    post transaction_transfer_match_path(outflow_entry), params: {
      transfer_match: {
        method: "new",
        target_account_id: accounts(:investment).id
      }
    }

    outflow_entry.reload
    outflow_txn = outflow_entry.entryable

    assert_equal "investment_contribution", outflow_txn.kind

    category = @user.family.investment_contributions_category
    assert_equal category, outflow_txn.category
  end

  test "shows annuity split preview before matching existing cash payment to new loan transaction" do
    loan_account = create_annuity_loan_account
    payment_entry = create_transaction(amount: 1798.65, account: accounts(:depository), date: Date.new(2024, 2, 1))

    assert_no_difference [ "Transfer.count", "Entry.count", "Transaction.count" ] do
      post transaction_transfer_match_path(payment_entry), params: {
        transfer_match: {
          method: "new",
          target_account_id: loan_account.id
        }
      }
    end

    assert_response :unprocessable_entity
    assert_select "[data-testid='loan-payment-split-preview']"
    assert_select "button[name='transfer_match[loan_payment_split_action]'][value='accept']"
    assert_select "button[name='transfer_match[loan_payment_split_action]'][value='unmatched']"
  end

  test "shows scheduled annuity loan payments as match choices" do
    create_annuity_loan_account
    payment_entry = create_transaction(amount: 1798.65, account: accounts(:depository), date: Date.new(2024, 2, 1))

    get new_transaction_transfer_match_path(payment_entry)

    assert_response :success
    assert_select "option[value='scheduled_loan_payment']", text: /Match scheduled loan payment/
    assert_select "option", text: /Annuity Mortgage due/
    assert_select "option", text: /principal/
    assert_select "option", text: /interest/
  end

  test "shows scheduled annuity loan payment choice for explicit first payment cadence" do
    create_annuity_loan_account(
      started_on: Date.new(2024, 12, 28),
      first_payment_on: Date.new(2025, 1, 28),
      initial_balance: 453407,
      annual_rate: 3.65,
      payment_amount: 2074.15,
      currency: "EUR"
    )
    payment_entry = create_transaction(amount: 2074.15, currency: "EUR", account: accounts(:depository), date: Date.new(2025, 3, 28))

    get new_transaction_transfer_match_path(payment_entry)

    assert_response :success
    assert_select "option[value='scheduled_loan_payment']", text: /Match scheduled loan payment/
    assert_select "option", text: /due Mar 28, 2025/
  end

  test "shows manual annuity loan payment periods when automatic date matching misses" do
    loan_account = create_annuity_loan_account
    payment_entry = create_transaction(amount: 1798.65, account: accounts(:depository), date: Date.new(2024, 4, 20))

    get new_transaction_transfer_match_path(payment_entry)

    assert_response :success
    assert_select "option[value='manual_loan_payment']", text: /Match loan payment manually/
    assert_select "option[value='#{loan_account.id}:3']", text: /period 3/
  end

  test "does not select manual annuity loan payment matching by default" do
    create_annuity_loan_account
    payment_entry = create_transaction(amount: 1798.65, account: accounts(:depository), date: Date.new(2024, 4, 20))

    get new_transaction_transfer_match_path(payment_entry)

    assert_response :success
    assert_select "select[name='transfer_match[method]'] option[value='manual_loan_payment']"
    assert_select "select[name='transfer_match[method]'] option[value='manual_loan_payment'][selected]", count: 0
    assert_select "select[name='transfer_match[method]'] option[value='new'][selected]"
  end

  test "limits manual annuity loan period options to nearby unpaid periods" do
    create_annuity_loan_account
    payment_entry = create_transaction(amount: 1798.65, account: accounts(:depository), date: Date.new(2024, 4, 20))

    get new_transaction_transfer_match_path(payment_entry)

    assert_response :success
    assert_select "select[name='transfer_match[manual_loan_payment_id]'] option", count: 12
  end

  test "scheduled annuity loan payment selection shows split preview" do
    loan_account = create_annuity_loan_account
    payment_entry = create_transaction(amount: 1798.65, account: accounts(:depository), date: Date.new(2024, 2, 1))

    assert_no_difference [ "Transfer.count", "Entry.count", "Transaction.count" ] do
      post transaction_transfer_match_path(payment_entry), params: {
        transfer_match: {
          method: "scheduled_loan_payment",
          scheduled_loan_account_id: loan_account.id
        }
      }
    end

    assert_response :unprocessable_entity
    assert_select "[data-testid='loan-payment-split-preview']"
    assert_select "button[name='transfer_match[loan_payment_split_action]'][value='accept']"
  end

  test "accepts scheduled annuity loan payment match" do
    loan_account = create_annuity_loan_account
    payment_entry = create_transaction(amount: 1798.65, account: accounts(:depository), date: Date.new(2024, 2, 1))

    assert_difference -> { Transfer.count } => 1,
      -> { Entry.count } => 3,
      -> { Transaction.count } => 3 do
      post transaction_transfer_match_path(payment_entry), params: {
        transfer_match: {
          method: "scheduled_loan_payment",
          scheduled_loan_account_id: loan_account.id,
          loan_payment_split_action: "accept"
        }
      }
    end

    payment_entry.reload
    transfer = Transfer.order(created_at: :desc).first

    assert payment_entry.split_parent?
    assert_in_delta 298.65, transfer.outflow_transaction.entry.amount, 0.01
    assert_in_delta(-298.65, transfer.inflow_transaction.entry.amount, 0.01)

    interest_entry = payment_entry.child_entries.where(name: "Interest for #{loan_account.name}").sole
    assert_in_delta 1500, interest_entry.amount, 0.01
  end

  test "accepts manually selected annuity loan payment period" do
    loan_account = create_annuity_loan_account
    payment_entry = create_transaction(amount: 1798.65, account: accounts(:depository), date: Date.new(2024, 4, 20))

    assert_no_difference [ "Transfer.count", "Entry.count", "Transaction.count" ] do
      post transaction_transfer_match_path(payment_entry), params: {
        transfer_match: {
          method: "manual_loan_payment",
          manual_loan_payment_id: "#{loan_account.id}:3"
        }
      }
    end

    assert_response :unprocessable_entity
    assert_select "[data-testid='loan-payment-split-preview']"

    assert_difference -> { Transfer.count } => 1,
      -> { Entry.count } => 3,
      -> { Transaction.count } => 3 do
      post transaction_transfer_match_path(payment_entry), params: {
        transfer_match: {
          method: "manual_loan_payment",
          manual_loan_payment_id: "#{loan_account.id}:3",
          loan_payment_split_action: "accept"
        }
      }
    end

    payment_entry.reload
    transfer = Transfer.order(created_at: :desc).first

    assert payment_entry.split_parent?
    assert_equal "3", transfer.inflow_transaction.extra.dig("loan_payment_split", "period_number").to_s
    assert_in_delta 301.64, transfer.outflow_transaction.entry.amount, 0.01
    assert_in_delta(-301.64, transfer.inflow_transaction.entry.amount, 0.01)
  end

  test "accepts annuity split when matching existing cash payment to new loan transaction" do
    loan_account = create_annuity_loan_account
    payment_entry = create_transaction(amount: 1798.65, account: accounts(:depository), date: Date.new(2024, 2, 1))

    assert_difference -> { Transfer.count } => 1,
      -> { Entry.count } => 3,
      -> { Transaction.count } => 3 do
      post transaction_transfer_match_path(payment_entry), params: {
        transfer_match: {
          method: "new",
          target_account_id: loan_account.id,
          loan_payment_split_action: "accept"
        }
      }
    end

    payment_entry.reload
    transfer = Transfer.order(created_at: :desc).first

    assert payment_entry.split_parent?
    assert_equal "loan_payment", transfer.outflow_transaction.kind
    assert_equal "funds_movement", transfer.inflow_transaction.kind
    assert_in_delta 298.65, transfer.outflow_transaction.entry.amount, 0.01
    assert_in_delta(-298.65, transfer.inflow_transaction.entry.amount, 0.01)

    interest_entry = payment_entry.child_entries.where(name: "Interest for #{loan_account.name}").sole
    assert_in_delta 1500, interest_entry.amount, 0.01
    assert_equal "standard", interest_entry.transaction.kind
  end

  private
    def create_annuity_loan_account(started_on: Date.new(2024, 1, 1), first_payment_on: nil, initial_balance: 300000, annual_rate: 6.0, payment_amount: nil, currency: "USD")
      loan = Loan.new(
        annuity_enabled: true,
        started_on: started_on,
        first_payment_on: first_payment_on,
        payment_cadence: "monthly",
        initial_balance: initial_balance,
        term_months: 360,
        rate_type: "fixed"
      )
      loan.loan_rate_periods.build(starts_on: started_on, annual_rate: annual_rate, payment_amount: payment_amount)

      @user.family.accounts.create!(
        name: "Annuity Mortgage",
        balance: initial_balance,
        currency: currency,
        accountable: loan
      )
    end
end

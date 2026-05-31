class Rule::ActionExecutor::SetAsTransferOrPayment < Rule::ActionExecutor
  def type
    "select"
  end

  def options
    family.accounts.alphabetically.pluck(:name, :id)
  end

  def execute(transaction_scope, value: nil, ignore_attribute_locks: false, rule_run: nil)
    target_account = family.accounts.find_by_id(value)
    return 0 unless target_account
    scope = transaction_scope.with_entry

    count_modified_resources(scope) do |txn|
      entry = txn.entry
      unless txn.transfer?
        transfer = nil
        Transfer.transaction do
          transfer = build_transfer(target_account, entry)
          transfer.save!

          # Use DESTINATION (inflow) account for kind, matching Transfer::Creator logic
          destination_account = transfer.inflow_transaction.entry.account
          outflow_kind = Transfer.kind_for_account(destination_account)
          outflow_attrs = { kind: outflow_kind }

          if outflow_kind == "investment_contribution"
            category = destination_account.family.investment_contributions_category
            outflow_attrs[:category] = category if category.present? && transfer.outflow_transaction.category_id.blank?
          end

          transfer.outflow_transaction.update!(outflow_attrs)
          transfer.inflow_transaction.update!(kind: "funds_movement")
        end

        transfer.sync_account_later
      end
    end
  end

  private
    def build_transfer(target_account, entry)
      if split_annuity_loan_payment?(target_account, entry)
        return build_split_annuity_loan_transfer(target_account, entry)
      end

      build_standard_transfer(target_account, entry)
    end

    def split_annuity_loan_payment?(target_account, entry)
      return false unless entry.amount.positive?
      return false unless target_account.loan? && target_account.loan.annuity_enabled?
      return false if entry.split_parent? || entry.split_child?

      loan_payment_split(target_account, entry)&.matched?
    end

    def build_split_annuity_loan_transfer(loan_account, entry)
      split = loan_payment_split(loan_account, entry)
      return build_standard_transfer(loan_account, entry) unless split.matched?

      split_parent_into_loan_payment!(loan_account, entry, split)
      principal_entry = entry.child_entries.find_by!(name: "Principal for #{loan_account.name}")

      loan_transaction = Transaction.new(
        kind: "funds_movement",
        extra: loan_payment_extra(split),
        entry: loan_account.entries.build(
          amount: (split.principal + split.extra_principal) * -1,
          currency: loan_account.currency,
          date: entry.date,
          name: "Payment from #{entry.account.name}",
          user_modified: true
        )
      )

      Transfer.new(
        inflow_transaction: loan_transaction,
        outflow_transaction: principal_entry.transaction,
        status: "confirmed"
      )
    end

    def split_parent_into_loan_payment!(loan_account, entry, split)
      principal_amount = split.principal + split.extra_principal

      entry.split!([
        {
          name: "Principal for #{loan_account.name}",
          amount: principal_amount,
          category_id: entry.transaction.category_id,
          excluded: false
        },
        {
          name: "Interest for #{loan_account.name}",
          amount: split.interest,
          category_id: entry.transaction.category_id,
          excluded: false
        }
      ])

      entry.child_entries.find_by!(name: "Principal for #{loan_account.name}").transaction.update!(
        extra: loan_payment_extra(split)
      )
      entry.child_entries.find_by!(name: "Interest for #{loan_account.name}").transaction.update!(
        kind: "standard",
        extra: loan_payment_extra(split)
      )
    end

    def build_standard_transfer(target_account, entry)
      missing_transaction = Transaction.new(
        entry: target_account.entries.build(
          amount: entry.amount * -1,
          currency: entry.currency,
          date: entry.date,
          name: "#{target_account.liability? ? "Payment" : "Transfer"} #{entry.amount.negative? ? "to #{target_account.name}" : "from #{entry.account.name}"}",
          user_modified: true,
        )
      )

      transfer = Transfer.find_or_initialize_by(
        inflow_transaction: entry.amount.positive? ? missing_transaction : entry.transaction,
        outflow_transaction: entry.amount.positive? ? entry.transaction : missing_transaction
      )
      transfer.status = "confirmed"
      transfer
    end

    def loan_payment_split(target_account, entry)
      Loan::PaymentSplitter.new(target_account.loan).split(
        payment_date: entry.date,
        amount: entry.amount
      )
    end

    def loan_payment_extra(split)
      {
        "loan_payment_split" => {
          "period_number" => split.period_number,
          "due_date" => split.due_date.to_s,
          "interest" => split.interest.to_s,
          "principal" => split.principal.to_s,
          "extra_principal" => split.extra_principal.to_s,
          "variance" => split.variance.to_s,
          "scheduled_payment" => split.scheduled_payment.to_s
        }
      }
    end
end

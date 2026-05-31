class TransferMatchesController < ApplicationController
  before_action :set_entry

  def new
    @accounts = Current.family.accounts.writable_by(Current.user).visible.alphabetically.where.not(id: @entry.account_id)
    @transfer_match_candidates = @entry.transaction.transfer_match_candidates
    @annuity_loan_payment_candidates = annuity_loan_payment_candidates
    @manual_annuity_loan_payment_candidates = manual_annuity_loan_payment_candidates
  end

  def create
    return unless require_account_permission!(@entry.account, redirect_path: transactions_path)

    target_account = resolve_target_account
    return unless require_account_permission!(target_account, redirect_path: transactions_path)

    if loan_payment_split_confirmation_required?(target_account)
      set_form_state
      @loan_payment_split_preview = loan_payment_split_preview(target_account)
      render :new, status: :unprocessable_entity
      return
    end

    Transfer.transaction do
      @transfer = build_transfer(target_account)
      @transfer.save!

      # Use DESTINATION (inflow) account for kind, matching Transfer::Creator logic
      destination_account = @transfer.inflow_transaction.entry.account
      outflow_kind = Transfer.kind_for_account(destination_account)
      outflow_attrs = { kind: outflow_kind }

      if outflow_kind == "investment_contribution"
        category = destination_account.family.investment_contributions_category
        outflow_attrs[:category] = category if category.present? && @transfer.outflow_transaction.category_id.blank?
      end

      @transfer.outflow_transaction.update!(outflow_attrs)
      @transfer.inflow_transaction.update!(kind: "funds_movement")
    end

    @transfer.sync_account_later

    redirect_back_or_to transactions_path, notice: t(".success")
  end

  private
    def set_entry
      @entry = Current.accessible_entries.find(params[:transaction_id])
    end

    def set_form_state
      @accounts = Current.family.accounts.writable_by(Current.user).visible.alphabetically.where.not(id: @entry.account_id)
      @transfer_match_candidates = @entry.transaction.transfer_match_candidates
      @annuity_loan_payment_candidates = annuity_loan_payment_candidates
      @manual_annuity_loan_payment_candidates = manual_annuity_loan_payment_candidates
    end

    def transfer_match_params
      if request.get?
        params.fetch(:transfer_match, ActionController::Parameters.new).permit(:method, :matched_entry_id, :target_account_id, :scheduled_loan_account_id, :manual_loan_payment_id, :loan_payment_split_action)
      else
        params.require(:transfer_match).permit(:method, :matched_entry_id, :target_account_id, :scheduled_loan_account_id, :manual_loan_payment_id, :loan_payment_split_action)
      end
    end

    def resolve_target_account
      if transfer_match_params[:method] == "scheduled_loan_payment"
        accessible_accounts.find(transfer_match_params[:scheduled_loan_account_id])
      elsif transfer_match_params[:method] == "manual_loan_payment"
        manual_loan_payment_selection.fetch(:account)
      elsif transfer_match_params[:method] == "new"
        accessible_accounts.find(transfer_match_params[:target_account_id])
      else
        Current.accessible_entries.find(transfer_match_params[:matched_entry_id]).account
      end
    end

    def build_transfer(target_account)
      if accepted_new_annuity_loan_payment?(target_account)
        return build_split_annuity_loan_transfer(target_account)
      end

      if transfer_match_params[:method] == "new"
        missing_transaction = Transaction.new(
          entry: target_account.entries.build(
            amount: @entry.amount * -1,
            currency: @entry.currency,
            date: @entry.date,
            name: "Transfer to #{@entry.amount.negative? ? @entry.account.name : target_account.name}",
            user_modified: true,
          )
        )

        transfer = Transfer.find_or_initialize_by(
          inflow_transaction: @entry.amount.positive? ? missing_transaction : @entry.transaction,
          outflow_transaction: @entry.amount.positive? ? @entry.transaction : missing_transaction
        )
        transfer.status = "confirmed"
        transfer
      else
        target_transaction = Current.accessible_entries.find(transfer_match_params[:matched_entry_id])

        transfer = Transfer.find_or_initialize_by(
          inflow_transaction: @entry.amount.negative? ? @entry.transaction : target_transaction.transaction,
          outflow_transaction: @entry.amount.negative? ? target_transaction.transaction : @entry.transaction
        )
        transfer.status = "confirmed"
        transfer
      end
    end

    def accepted_new_annuity_loan_payment?(target_account)
      %w[new scheduled_loan_payment manual_loan_payment].include?(transfer_match_params[:method]) &&
        transfer_match_params[:loan_payment_split_action] == "accept" &&
        @entry.amount.positive? &&
        target_account.loan? &&
        target_account.loan.annuity_enabled?
    end

    def loan_payment_split_confirmation_required?(target_account)
      return false if transfer_match_params[:loan_payment_split_action].present?
      return false unless @entry.amount.positive? && target_account.loan? && target_account.loan.annuity_enabled?

      loan_payment_split_preview(target_account)&.matched?
    end

    def loan_payment_split_preview(target_account)
      return nil unless target_account.loan? && target_account.loan.annuity_enabled?

      Loan::PaymentSplitter.new(target_account.loan).split(
        payment_date: @entry.date,
        amount: @entry.amount.abs,
        period_number: manual_loan_payment_period_number_for(target_account)
      )
    end

    def annuity_loan_payment_candidates
      return [] unless @entry.amount.positive?

      @accounts
        .select { |account| account.loan? && account.loan.annuity_enabled? }
        .filter_map do |account|
          split = loan_payment_split_preview(account)
          next unless split&.matched?

          {
            account: account,
            split: split
          }
        end
    end

    def manual_annuity_loan_payment_candidates
      return [] unless @entry.amount.positive?

      @accounts
        .select { |account| account.loan? && account.loan.annuity_enabled? }
        .flat_map do |account|
          paid_period_numbers = account.loan.paid_annuity_period_numbers

          account.loan.amortization_schedule(as_of: @entry.date).rows
            .reject { |row| paid_period_numbers.include?(row.period_number) }
            .map do |row|
              split = Loan::PaymentSplitter.new(account.loan).split(
                payment_date: @entry.date,
                amount: @entry.amount.abs,
                paid_period_numbers: paid_period_numbers,
                period_number: row.period_number
              )

              {
                account: account,
                split: split,
                value: manual_loan_payment_value(account, row.period_number)
              }
            end
        end
        .sort_by { |candidate| (candidate.fetch(:split).due_date - @entry.date).abs }
    end

    def manual_loan_payment_selection
      account_id, period_number = transfer_match_params[:manual_loan_payment_id].to_s.split(":", 2)
      account = accessible_accounts.find(account_id)
      period_number = period_number.to_i

      unless account.loan? && account.loan.annuity_enabled? && period_number.positive?
        raise ActiveRecord::RecordNotFound
      end

      { account: account, period_number: period_number }
    end

    def manual_loan_payment_period_number_for(target_account)
      return nil unless transfer_match_params[:method] == "manual_loan_payment"

      selection = manual_loan_payment_selection
      return nil unless selection.fetch(:account).id == target_account.id

      selection.fetch(:period_number)
    end

    def manual_loan_payment_value(account, period_number)
      "#{account.id}:#{period_number}"
    end

    def build_split_annuity_loan_transfer(loan_account)
      split = Loan::PaymentSplitter.new(loan_account.loan).split(
        payment_date: @entry.date,
        amount: @entry.amount.abs,
        period_number: manual_loan_payment_period_number_for(loan_account)
      )

      return build_transfer_without_split(loan_account) unless split.matched?

      split_parent_into_loan_payment!(loan_account, split)
      principal_entry = @entry.child_entries.find_by!(name: "Principal for #{loan_account.name}")

      loan_transaction = Transaction.new(
        kind: "funds_movement",
        extra: loan_payment_extra(split),
        entry: loan_account.entries.build(
          amount: (split.principal + split.extra_principal) * -1,
          currency: loan_account.currency,
          date: @entry.date,
          name: "Payment from #{@entry.account.name}",
          user_modified: true
        )
      )

      Transfer.new(
        inflow_transaction: loan_transaction,
        outflow_transaction: principal_entry.transaction,
        status: "confirmed"
      )
    end

    def split_parent_into_loan_payment!(loan_account, split)
      principal_amount = split.principal + split.extra_principal

      @entry.split!([
        {
          name: "Principal for #{loan_account.name}",
          amount: principal_amount,
          category_id: @entry.transaction.category_id,
          excluded: false
        },
        {
          name: "Interest for #{loan_account.name}",
          amount: split.interest,
          category_id: @entry.transaction.category_id,
          excluded: false
        }
      ])

      @entry.child_entries.find_by!(name: "Principal for #{loan_account.name}").transaction.update!(
        extra: loan_payment_extra(split)
      )
      @entry.child_entries.find_by!(name: "Interest for #{loan_account.name}").transaction.update!(
        kind: "standard",
        extra: loan_payment_extra(split)
      )
    end

    def build_transfer_without_split(target_account)
      missing_transaction = Transaction.new(
        entry: target_account.entries.build(
          amount: @entry.amount * -1,
          currency: @entry.currency,
          date: @entry.date,
          name: "Transfer to #{@entry.amount.negative? ? @entry.account.name : target_account.name}",
          user_modified: true,
        )
      )

      Transfer.new(
        inflow_transaction: @entry.amount.positive? ? missing_transaction : @entry.transaction,
        outflow_transaction: @entry.amount.positive? ? @entry.transaction : missing_transaction,
        status: "confirmed"
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

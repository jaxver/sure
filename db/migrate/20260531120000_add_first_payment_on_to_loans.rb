class AddFirstPaymentOnToLoans < ActiveRecord::Migration[7.2]
  def change
    add_column :loans, :first_payment_on, :date
  end
end

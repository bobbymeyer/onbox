class StampsController < ApplicationController
  before_action :set_stamp, only: [ :edit, :update, :destroy ]

  def index
    @stamps = Stamp.order(:card_type).by_use
  end

  def new
    @stamp = Stamp.new(action: { "kind" => "instruct" })
  end

  def create
    @stamp = Stamp.new(stamp_params)
    if @stamp.save
      redirect_to stamps_path, notice: "Stamp created"
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @stamp.update(stamp_params)
      redirect_to stamps_path, notice: "Stamp updated"
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @stamp.destroy!
    redirect_to stamps_path, notice: "Stamp deleted"
  end

  private
    def set_stamp
      @stamp = Stamp.find(params[:id])
    end

    def stamp_params
      params.expect(stamp: [ :label, :card_type, :template, :requires_flip, :action_json, :successors_json ])
    end
end

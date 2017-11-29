
class Standard
  # @!group WaterHeaterMixed

  # Applies the standard efficiency ratings and typical losses and paraisitic loads to this object.
  # Efficiency and skin loss coefficient (UA)
  # Per PNNL http://www.energycodes.gov/sites/default/files/documents/PrototypeModelEnhancements_2014_0.pdf
  # Appendix A: Service Water Heating
  #
  # @return [Bool] true if successful, false if not
  def water_heater_mixed_apply_efficiency(water_heater_mixed)
    # Get the capacity of the water heater
    # TODO add capability to pull autosized water heater capacity
    # if the Sizing:WaterHeater object is ever implemented in OpenStudio.
    capacity_w = water_heater_mixed.heaterMaximumCapacity
    if capacity_w.empty?
      OpenStudio.logFree(OpenStudio::Warn, 'openstudio.standards.WaterHeaterMixed', "For #{water_heater_mixed.name}, cannot find capacity, standard will not be applied.")
      return false
    else
      capacity_w = capacity_w.get
    end
    capacity_btu_per_hr = OpenStudio.convert(capacity_w, 'W', 'Btu/hr').get

    # Get the volume of the water heater
    # TODO add capability to pull autosized water heater volume
    # if the Sizing:WaterHeater object is ever implemented in OpenStudio.
    volume_m3 = water_heater_mixed.tankVolume
    if volume_m3.empty?
      OpenStudio.logFree(OpenStudio::Warn, 'openstudio.standards.WaterHeaterMixed', "For #{water_heater_mixed.name}, cannot find volume, standard will not be applied.")
      return false
    else
      volume_m3 = volume_m3.get
    end
    volume_gal = OpenStudio.convert(volume_m3, 'm^3', 'gal').get

    # Get the heater fuel type
    fuel_type = water_heater_mixed.heaterFuelType
    unless fuel_type == 'NaturalGas' || fuel_type == 'Electricity'
      OpenStudio.logFree(OpenStudio::Warn, 'openstudio.standards.WaterHeaterMixed', "For #{water_heater_mixed.name}, fuel type of #{fuel_type} is not yet supported, standard will not be applied.")
    end

    # Get the water heater properties
    search_criteria = {}
    search_criteria['template'] = template
    search_criteria['fuel_type'] = fuel_type
    wh_props = model_find_object(standards_data['water_heaters'], search_criteria, capacity_btu_per_hr)
    unless wh_props
      OpenStudio.logFree(OpenStudio::Warn, 'openstudio.standards.BoilerHotWater', "For #{water_heater_mixed.name}, cannot find water heater properties, cannot apply efficiency standard.")
      return false
    end

    # Calculate the water heater efficiency and
    # skin loss coefficient (UA) using different methods,
    # depending on the metrics specified by the standard
    water_heater_eff = nil
    ua_btu_per_hr_per_f = nil

    # Rarely specified by thermal efficiency alone
    if wh_props['thermal_efficiency'] && !wh_props['standby_loss_capacity_allowance']
      et = wh_props['thermal_efficiency']
      water_heater_eff = et
      # Fixed UA
      ua_btu_per_hr_per_f = 11.37
    end

    # Typically specified this way for small electric water heaters
    # and small natural gas water heaters
    if wh_props['energy_factor_base'] && wh_props['energy_factor_volume_derate']
      # Calculate the energy factor (EF)
      base_ef = wh_props['energy_factor_base']
      vol_drt = wh_props['energy_factor_volume_derate']
      ef = base_ef - (vol_drt * volume_gal)
      # Calculate the skin loss coefficient (UA)
      # differently depending on the fuel type
      if fuel_type == 'Electricity'
        # Fixed water heater efficiency per PNNL
        water_heater_eff = 1
        ua_btu_per_hr_per_f = (41_094 * (1 / ef - 1)) / (24 * 67.5)
      elsif fuel_type == 'NaturalGas'
        # Fixed water heater thermal efficiency per PNNL
        water_heater_eff = 0.82
        # Calculate the Recovery Efficiency (RE)
        # based on a fixed capacity of 75,000 Btu/hr
        # and a fixed volume of 40 gallons by solving
        # this system of equations:
        # ua = (1/.95-1/re)/(67.5*(24/41094-1/(re*cap)))
        # 0.82 = (ua*67.5+cap*re)/cap
        cap = 75_000.0
        re = (Math.sqrt(6724 * ef**2 * cap**2 + 40_409_100 * ef**2 * cap - 28_080_900 * ef * cap + 29_318_000_625 * ef**2 - 58_636_001_250 * ef + 29_318_000_625) + 82 * ef * cap + 171_225 * ef - 171_225) / (200 * ef * cap)
        # Calculate the skin loss coefficient (UA)
        # based on the actual capacity.
        ua_btu_per_hr_per_f = (water_heater_eff - re) * capacity_btu_per_hr / 67.5
      end
    end

    # Typically specified this way for large electric water heaters
    if wh_props['standby_loss_base'] && wh_props['standby_loss_volume_allowance']
      # Fixed water heater efficiency per PNNL
      water_heater_eff = 1
      # Calculate the max allowable standby loss (SL)
      sl_base = wh_props['standby_loss_base']
      sl_drt = wh_props['standby_loss_volume_allowance']
      sl_btu_per_hr = sl_base + (sl_drt * Math.sqrt(volume_gal))
      # Calculate the skin loss coefficient (UA)
      ua_btu_per_hr_per_f = sl_btu_per_hr / 70
    end

    # Typically specified this way for newer large electric water heaters
    if wh_props['hourly_loss_base'] && wh_props['hourly_loss_volume_allowance']
      # Fixed water heater efficiency per PNNL
      water_heater_eff = 1
      # Calculate the percent loss per hr
      hr_loss_base = wh_props['hourly_loss_base']
      hr_loss_allow = wh_props['hourly_loss_volume_allowance']
      hrly_loss_pct = (hr_loss_base + hr_loss_allow / volume_gal) / 100
      # Convert to Btu/hr, assuming:
      # Water at 120F, density = 8.25 lb/gal
      # 1 Btu to raise 1 lb of water 1 F
      # Therefore 8.25 Btu / gal of water * deg F
      # 70F delta-T between water and zone
      hrly_loss_btu_per_hr = hrly_loss_pct * volume_gal * 8.25 * 70
      # Calculate the skin loss coefficient (UA)
      ua_btu_per_hr_per_f = hrly_loss_btu_per_hr / 70
    end

    # Typically specified this way for large natural gas water heaters
    if wh_props['standby_loss_capacity_allowance'] && wh_props['standby_loss_volume_allowance'] && wh_props['thermal_efficiency']
      sl_cap_adj = wh_props['standby_loss_capacity_allowance']
      sl_vol_drt = wh_props['standby_loss_volume_allowance']
      et = wh_props['thermal_efficiency']
      # Calculate the max allowable standby loss (SL)
      sl_btu_per_hr = (capacity_btu_per_hr / sl_cap_adj + sl_vol_drt * Math.sqrt(volume_gal))
      # Calculate the skin loss coefficient (UA)
      ua_btu_per_hr_per_f = (sl_btu_per_hr * et) / 70
      # Calculate water heater efficiency
      water_heater_eff = (ua_btu_per_hr_per_f * 70 + capacity_btu_per_hr * et) / capacity_btu_per_hr
    end

    # Ensure that efficiency and UA were both set\
    if water_heater_eff.nil?
      OpenStudio.logFree(OpenStudio::Warn, 'openstudio.standards.WaterHeaterMixed', "For #{water_heater_mixed.name}, cannot calculate efficiency, cannot apply efficiency standard.")
      return false
    end

    if ua_btu_per_hr_per_f.nil?
      OpenStudio.logFree(OpenStudio::Warn, 'openstudio.standards.WaterHeaterMixed', "For #{water_heater_mixed.name}, cannot calculate UA, cannot apply efficiency standard.")
      return false
    end

    # Convert to SI
    ua_btu_per_hr_per_c = OpenStudio.convert(ua_btu_per_hr_per_f, 'Btu/hr*R', 'W/K').get

    # Set the water heater properties
    # Efficiency
    water_heater_mixed.setHeaterThermalEfficiency(water_heater_eff)
    # Skin loss
    water_heater_mixed.setOffCycleLossCoefficienttoAmbientTemperature(ua_btu_per_hr_per_c)
    water_heater_mixed.setOnCycleLossCoefficienttoAmbientTemperature(ua_btu_per_hr_per_c)
    # TODO: Parasitic loss (pilot light)
    # PNNL document says pilot lights were removed, but IDFs
    # still have the on/off cycle parasitic fuel consumptions filled in
    water_heater_mixed.setOnCycleParasiticFuelType(fuel_type)
    # self.setOffCycleParasiticFuelConsumptionRate(??)
    water_heater_mixed.setOnCycleParasiticHeatFractiontoTank(0)
    water_heater_mixed.setOffCycleParasiticFuelType(fuel_type)
    # self.setOffCycleParasiticFuelConsumptionRate(??)
    water_heater_mixed.setOffCycleParasiticHeatFractiontoTank(0.8)

    # Append the name with standards information
    water_heater_mixed.setName("#{water_heater_mixed.name} #{water_heater_eff.round(3)} Therm Eff")
    OpenStudio.logFree(OpenStudio::Info, 'openstudio.model.WaterHeaterMixed', "For #{template}: #{water_heater_mixed.name}; thermal efficiency = #{water_heater_eff.round(3)}, skin-loss UA = #{ua_btu_per_hr_per_f.round}Btu/hr")

    return true
  end

  # Applies the correct fuel type for the water heaters
  # in the baseline model.  For most standards and for most building
  # types, the baseline uses the same fuel type as the proposed.
  #
  # @param building_type [String] the building type
  # @return [Bool] returns true if successful, false if not.
  def water_heater_mixed_apply_prm_baseline_fuel_type(water_heater_mixed, building_type)
    # baseline is same as proposed per Table G3.1 item 11.b
    return true # Do nothing
  end

  # Finds capacity in Btu/hr
  #
  # @return [Double] capacity in Btu/hr to be used for find object
  def water_heater_mixed_find_capacity(water_heater_mixed)
    # Get the coil capacity
    capacity_w = nil
    if water_heater_mixed.heaterMaximumCapacity.is_initialized
      capacity_w = water_heater_mixed.heaterMaximumCapacity.get
    elsif water_heater_mixed.autosizedHeaterMaximumCapacity.is_initialized
      capacity_w = water_heater_mixed.autosizedHeaterMaximumCapacity.get
    else
      OpenStudio.logFree(OpenStudio::Warn, 'openstudio.standards.WaterHeaterMixed', "For #{water_heater_mixed.name} capacity is not available.")
      return false
    end

    # Convert capacity to Btu/hr
    capacity_btu_per_hr = OpenStudio.convert(capacity_w, 'W', 'Btu/hr').get

    return capacity_btu_per_hr
  end
end
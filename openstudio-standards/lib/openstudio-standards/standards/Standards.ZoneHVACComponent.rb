# open the class to add methods to apply HVAC efficiency standards
class OpenStudio::Model::ZoneHVACComponent
  # Sets the fan power of zone level HVAC equipment 
  # (PTACs, PTHPs, Fan Coils, and Unit Heaters)
  # based on the W/cfm specified in the standard.
  #
  # @param template [String] the template base requirements on
  # @return [Bool] returns true if successful, false if not
  def apply_prm_baseline_fan_power(template)
    OpenStudio.logFree(OpenStudio::Debug, 'openstudio.model.ZoneHVACComponent', "Setting fan power for #{name}.")

    # Convert this to the actual class type
    zone_hvac = if to_ZoneHVACFourPipeFanCoil.is_initialized
                  to_ZoneHVACFourPipeFanCoil.get
                elsif to_ZoneHVACUnitHeater.is_initialized
                  to_ZoneHVACUnitHeater.get
                elsif to_ZoneHVACPackagedTerminalAirConditioner.is_initialized
                  to_ZoneHVACPackagedTerminalAirConditioner.get
                elsif to_ZoneHVACPackagedTerminalHeatPump.is_initialized
                  to_ZoneHVACPackagedTerminalHeatPump.get
                else
                  nil
                end

    # Do nothing for other types of zone HVAC equipment
    if zone_hvac.nil?
      return false
    end

    # Determine the W/cfm
    fan_efficacy_w_per_cfm = 0.3

    # Convert efficacy to metric
    # 1 cfm = 0.0004719 m^3/s
    fan_efficacy_w_per_m3_per_s = fan_efficacy_w_per_cfm / 0.0004719

    # Get the fan
    fan = if zone_hvac.supplyAirFan.to_FanConstantVolume.is_initialized
            zone_hvac.supplyAirFan.to_FanConstantVolume.get
          elsif zone_hvac.supplyAirFan.to_FanVariableVolume.is_initialized
            zone_hvac.supplyAirFan.to_FanVariableVolume.get
          elsif zone_hvac.supplyAirFan.to_FanOnOff.is_initialized
            zone_hvac.supplyAirFan.to_FanOnOff.get
          end

    # Get the maximum flow rate through the fan
    max_air_flow_rate = nil
    if fan.autosizedMaximumFlowRate.is_initialized
      max_air_flow_rate = fan.autosizedMaximumFlowRate.get
    elsif fan.maximumFlowRate.is_initialized
      max_air_flow_rate = fan.maximumFlowRate.get
    end
    max_air_flow_rate_cfm = OpenStudio.convert(max_air_flow_rate, 'm^3/s', 'ft^3/min').get

    # Set the impeller efficiency
    fan.change_impeller_efficiency(fan.baseline_impeller_efficiency(template))

    # Set the motor efficiency, preserving the impeller efficency.
    # For zone HVAC fans, a bhp lookup of 0.5bhp is always used because
    # they are assumed to represent a series of small fans in reality.
    fan.apply_standard_minimum_motor_efficiency(template, fan.brake_horsepower)

    # Calculate a new pressure rise to hit the target W/cfm
    fan_tot_eff = fan.fanEfficiency
    fan_rise_new_pa = fan_efficacy_w_per_m3_per_s * fan_tot_eff
    fan.setPressureRise(fan_rise_new_pa)

    # Calculate the newly set efficacy
    fan_power_new_w = fan_rise_new_pa * max_air_flow_rate / fan_tot_eff
    fan_efficacy_new_w_per_cfm = fan_power_new_w / max_air_flow_rate_cfm
    OpenStudio.logFree(OpenStudio::Info, 'openstudio.model.ZoneHVACComponent', "For #{name}: fan efficacy set to #{fan_efficacy_new_w_per_cfm.round(2)} W/cfm.")

    return true
  end

  # Apply all standard required controls to the zone equipment
  #
  # @return [Bool] returns true if successful, false if not
  def apply_standard_controls(template)

    # Vestibule heating control
    if self.vestibule_heating_control_required?(template)
      self.apply_vestibule_heating_control
    end

    return true
  end

  # Determine if vestibule heating control is required.
  # Required for 0.1-2013 per 6.4.3.9.
  # @return [Bool] returns true if successful, false if not
  def vestibule_heating_control_required?(template)
    # Do nothing for vintages before 90.1-2013
    return false unless template == '90.1-2013'

    # Ensure that the equipment is assigned to a thermal zone
    if self.thermalZone.empty?
      OpenStudio.logFree(OpenStudio::Warn, 'openstudio.model.ZoneHVACComponent', "For #{name}: equipment is not assigned to a thermal zone, cannot apply vestibule heating control.")
      return false
    end

    # Only applies to equipment that is in vestibule zones
    return true if self.thermalZone.get.vestibule?

    # If here, vestibule heating control not required
    return false
  end

  # Turns off vestibule heating below 45F
  #
  # @return [Bool] returns true if successful, false if not
  def apply_vestibule_heating_control

    # Ensure that the equipment is assigned to a thermal zone
    if self.thermalZone.empty?
      OpenStudio.logFree(OpenStudio::Warn, 'openstudio.model.ZoneHVACComponent', "For #{name}: equipment is not assigned to a thermal zone, cannot apply vestibule heating control.")
      return true
    end

    # Convert this to the actual class type
    zone_hvac = if to_ZoneHVACFourPipeFanCoil.is_initialized
                  to_ZoneHVACFourPipeFanCoil.get
                elsif to_ZoneHVACUnitHeater.is_initialized
                  to_ZoneHVACUnitHeater.get
                elsif to_ZoneHVACPackagedTerminalAirConditioner.is_initialized
                  to_ZoneHVACPackagedTerminalAirConditioner.get
                elsif to_ZoneHVACPackagedTerminalHeatPump.is_initialized
                  to_ZoneHVACPackagedTerminalHeatPump.get
                else
                  nil
                end

    # Do nothing for other types of zone HVAC equipment
    if zone_hvac.nil?
      return true
    end

    # Get the heating coil and fan
    htg_coil = zone_hvac.heatingCoil
    htg_coil = if htg_coil.to_CoilHeatingGas.is_initialized
                 htg_coil.to_CoilHeatingGas.get
               elsif htg_coil.to_CoilHeatingElectric.is_initialized
                 htg_coil.to_CoilHeatingElectric.get
               elsif htg_coil.to_CoilHeatingWater.is_initialized
                 htg_coil.to_CoilHeatingWater.get
               elsif htg_coil.to_CoilHeatingDXSingleSpeed.is_initialized
                 htg_coil.to_CoilHeatingDXSingleSpeed.get
               end

    fan = zone_hvac.supplyAirFan
    fan = if fan.to_FanOnOff.is_initialized
            fan.to_FanOnOff.get
          elsif fan.to_FanConstantVolume.is_initialized
            fan.to_FanConstantVolume.get
          elsif fan.to_FanVariableVolume.is_initialized
            fan.to_FanVariableVolume.get
          end

    # Get existing heater availability schedule if present
    # or create a new one
    avail_sch = nil
    avail_sch_name = 'VestibuleHeaterAvailSch'
    if self.model.getScheduleConstantByName(avail_sch_name).is_initialized
      avail_sch = self.model.getScheduleConstantByName(avail_sch_name).get
    else
      avail_sch = OpenStudio::Model::ScheduleConstant.new(self.model)
      avail_sch.setName(avail_sch_name)
      avail_sch.setValue(1)
    end

    # Replace the existing availabilty schedule with the one
    # that will be controlled via EMS
    htg_coil.setAvailabilitySchedule(avail_sch)
    fan.setAvailabilitySchedule(avail_sch)

    # Clean name of zone HVAC
    equip_name_clean = zone_hvac.name.get.to_s.gsub(/\W/, '').delete('_')
    # If the name starts with a number, prepend with a letter
    if equip_name_clean[0] =~ /[0-9]/
      equip_name_clean = "EQUIP#{equip_name_clean}"
    end

    # Sensors
    # Get existing OAT sensor if present
    oat_db_c_sen = nil
    if self.model.getEnergyManagementSystemSensorByName('OATVestibule').is_initialized
      oat_db_c_sen = self.model.getEnergyManagementSystemSensorByName('OATVestibule').get
    else
      oat_db_c_sen = OpenStudio::Model::EnergyManagementSystemSensor.new(model, 'Site Outdoor Air Drybulb Temperature')
      oat_db_c_sen.setName("OATVestibule")
      oat_db_c_sen.setKeyName("Environment")
    end

    # Actuators
    avail_sch_act = OpenStudio::Model::EnergyManagementSystemActuator.new(avail_sch, 'Schedule:Constant', 'Schedule Value')
    avail_sch_act.setName("#{equip_name_clean}VestHtgAvailSch")

    # Programs
    htg_lim_f = 45
    vestibule_htg_prg = OpenStudio::Model::EnergyManagementSystemProgram.new(model)
    vestibule_htg_prg.setName("#{equip_name_clean}VestHtgPrg")
    vestibule_htg_prg_body = <<-EMS
    IF #{oat_db_c_sen.handle} > #{OpenStudio.convert(htg_lim_f, 'F', 'C').get}
      SET #{avail_sch_act.handle} = 0
    ENDIF
    EMS
    vestibule_htg_prg.setBody(vestibule_htg_prg_body)

    # Program Calling Managers
    vestibule_htg_mgr = OpenStudio::Model::EnergyManagementSystemProgramCallingManager.new(model)
    vestibule_htg_mgr.setName("#{equip_name_clean}VestHtgMgr")
    vestibule_htg_mgr.setCallingPoint('BeginTimestepBeforePredictor')
    vestibule_htg_mgr.addProgram(vestibule_htg_prg)

    OpenStudio.logFree(OpenStudio::Info, 'openstudio.standards.AirLoopHVAC', "For #{self.name}: Vestibule heating control applied, heating disabled below #{htg_lim_f} F.")

    return true
  end
end
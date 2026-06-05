#!/usr/bin/env bash
# shellcheck disable=SC2154,SC2153,SC2012
# Remove any old files
rm -f "${UMBRELLA_PREP_CHEM_DATA}"/smoke.init*nc # why we need this?

# RAVE_INPUT is provided by the job card directly
ECO_INPUTDIR=${CHEM_INPUT}/aux/ecoregion/raw/
FMC_INPUTDIR=${CHEM_INPUT}/aux/FMC/raw/${YYYY}/${MM}/

# output directories
RAVE_OUTPUTDIR=${DATA}
ECO_OUTPUTDIR=${DATA}
FMC_OUTPUTDIR=${DATA}

# Process NGFS CSV files directly to the model:
if [[ "${FIRE_DATASET}" == "NGFS" ]]; then
    
    # Check whether FIRE_INPUT has two directories:
    read -r -a fire_paths <<< "${FIRE_INPUT}"
    if (( ${#fire_paths[@]} == 2 )); then
        NGFS_CSV_GOES_WEST="${fire_paths[0]}"
        NGFS_CSV_GOES_EAST="${fire_paths[1]}"
    else
        echo "Option FIRE_DATASET='NGFS' needs two paths defined in FIRE_INPUT separated by space."
        echo "Example: FIRE_INPUT=\"/path/to/csv/goes/west /path/to/csv/goes/east\""
        echo "Expected 2 paths defined in FIRE_INPUT, found \"${FIRE_INPUT}\""
        echo "Aborting..."; exit 1
    fi
    
    NGFS_PROCESSING_STEP_MINUTES=60 # hardcoded to create files every 1 hour
    export NGFS_OUTPUT=$PWD
    export NGFS_DIR="${NGFS_PROCESSOR_DIR}"
    
    # Define if we go forward or back in time
    if [[ "${EBB_DCYCLE}" -eq -1 ]]; then
        time_direction="ago"
        loop_limit=24
    else
        time_direction=""
        loop_limit=${my_fcst_length}
    fi
    
    # Process hourly files
    MAX_PARALLEL=13; nrun=0
    for (( NGFSH=0; NGFSH<=loop_limit; NGFSH++ )); do
        [[ "${EBB_DCYCLE}" -eq -1 ]] && time_modifier="1 day ago ${NGFSH} hours" || time_modifier="${NGFSH} hours"
        
        NGFS_START=$(date -d "${YYYY}-${MM}-${DD} 00:00:00 ${time_modifier}" +"%Y-%m-%d_%H:%M:%S")
        
        # srun --ntasks=1 --cpus-per-task=1 --mem=0  python -u ${NGFS_PROCESSOR_DIR}/process_bysat_NGFS.py \
        srun --exclusive --ntasks=1 --cpus-per-task=1 --mem=0 python -u "${NGFS_PROCESSOR_DIR}/process_bysat_NGFS.py" \
                "${NGFS_START}" \
                "${NGFS_PROCESSING_STEP_MINUTES}" \
                "${NGFS_CSV_GOES_WEST}" \
                "${NGFS_CSV_GOES_EAST}" &

        ((nrun++))
        if (( nrun % MAX_PARALLEL == 0 )); then
            wait
        fi
    done
    
    wait # wait for any remaining processes to finish
    # overwrite the FIRE_INPUT variable
    export FIRE_INPUT="${NGFS_OUTPUT}"
fi

# Call regridder:
srun --ntasks=1 --cpus-per-task=1 --mem=0 python -u "${SCRIPT}" \
               "${FIRE_DATASET}" \
               "${DATA}" \
               "${FIRE_INPUT}" \
               "${RAVE_OUTPUTDIR}" \
               "${INTERP_WEIGHTS_DIR}" \
               "${YYYY}${MM}${DD}${HH}"
mkdir -p logs
mv ./*.log ./*.ESMF_LogFile logs || echo "could not move logs"
#
# Loop through the hours and link the files so they have the correct filename and variable names 
# TODO - Update variable names via outside script or within regrid.py -- mapping table?
for ihour in $(seq 0 "${my_fcst_length}");
do
  if (( ihour > 24 )); then
    ihour2=$((ihour-24))
  else
    ihour2=${ihour}
  fi
  if [[ "${EBB_DCYCLE}" == -1 ]]; then
     # Peristence emissions, only 24 forecasts are possible
     # Beyond that we need to repeat the emissions
     timestr1=$(date +%Y%m%d%H -d "$previous_day + $ihour2 hours")
  else
     # Either NOWcast (1 emission file per current forecast hour) or
     # Forecasted emissions requiring the previous 24 hours
     timestr1=$(date +%Y%m%d%H -d "$current_day + $ihour hours")
  fi

  timestr2=$(date +%Y-%m-%d_%H -d "$current_day + $ihour hours")
  timestr3=$(date +%Y-%m-%d_%H:00:00 -d "$current_day + $ihour hours")
  #
  EMISFILE="${UMBRELLA_PREP_CHEM_DATA}/smoke.init.retro.${timestr2}.00.00.nc"
  EMISFILE2="${RAVE_OUTPUTDIR}/${MESH_NAME}-${FIRE_DATASET}-${timestr1}.nc"
  if [[ -r "${EMISFILE2}" ]]; then
    ncrename -v PM25,e_bb_in_smoke_fine "${EMISFILE2}"
    ncrename -v FRP_MEAN,frp_in -v FRE,fre_in "${EMISFILE2}"
    if [[ "${FIRE_DATASET}" != "NGFS" ]]; then
        ncrename -v SO2,e_bb_in_so2 "${EMISFILE2}"
        ncrename -v CH4,e_bb_in_ch4 "${EMISFILE2}"
        ncrename -v PM10,e_bb_in_smoke_coarse "${EMISFILE2}"
        ncrename -v CO,e_bb_in_co "${EMISFILE2}"
        ncrename -v NH3,e_bb_in_nh3 "${EMISFILE2}"
        ncrename -v NOx,e_bb_in_nox "${EMISFILE2}"
    fi
    ln -sf "${EMISFILE2}" "${EMISFILE}"
    ncap2 -O -s 'frp_in=frp_in.ttl($nkwildfire)' -s 'fre_in=fre_in.ttl($nkwildfire)' "${EMISFILE}" "${EMISFILE}"
  else
    dummyRAVE=${FIXrrfs}/chemistry/RAVE/RAVE.dummy.${MESH_NAME}.nc
    if [[ -s ${dummyRAVE} ]]; then
      cp "${dummyRAVE}" "${EMISFILE}"
    else
      echo "${dummyRAVE} not found, stop the workflow..."
      err_exit
    fi
  fi
  # TODO temporary fix until YAML options are built into regriddder
  ncks -O -6 "${EMISFILE}" "${EMISFILE}"
  ncks -A -v xtime ./init.nc  "${EMISFILE}"
  #shellcheck disable=SC2086
  ncap2 -O -s xtime=\"${timestr3}\" "${EMISFILE}" "${EMISFILE}"  
done
#
#
echo "Concatenating hourly files for use in forecast mode"
# Concatenate for ebb2
nc_vars="frp_in,fre_in,e_bb_in_smoke_fine"
[[ "${FIRE_DATASET}" == "RAVE" ]] && nc_vars="${nc_vars},e_bb_in_so2,e_bb_in_ch4,e_bb_in_smoke_coarse,e_bb_in_nh3"
ncrcat -v "${nc_vars}" "${UMBRELLA_PREP_CHEM_DATA}"/smoke.init.retro.*.00.00.nc "${UMBRELLA_PREP_CHEM_DATA}"/smoke.init.nc
#
# Calculate previous 24 hour average HWP
#
# TODO - presently hwp and totprcp have constant values
ncap2 -O -s 'hwp_prev24=0.0*frp_in+30.' -s 'totprcp_prev24=0.0*frp_in+0.1' "${UMBRELLA_PREP_CHEM_DATA}"/smoke.init.nc "${UMBRELLA_PREP_CHEM_DATA}"/smoke.init.nc
ncrename -v frp_in,frp_prev24 -v fre_in,fre_prev24 "${UMBRELLA_PREP_CHEM_DATA}"/smoke.init.nc
#
# Emissions to be calculated inside of model
if [[ ! -r "${ECO_OUTPUTDIR}/ecoregions_${MESH_NAME}_mpas.nc" ]] && [[ -r "${ECO_INPUTDIR}/veg_map.nc" ]]; then
   echo "Regridding ECO_REGION"
   srun python -u "${SCRIPT}"   \
                   "ECOREGION" \
                   "${DATA}" \
                   "${ECO_INPUTDIR}" \
                   "${ECO_OUTPUTDIR}" \
                   "${INTERP_WEIGHTS_DIR}" \
                   "${YYYY}${MM}${DD}${HH}"

  ncks -A -v ecoregion_ID "${ECO_OUTPUTDIR}/ecoregions_${MESH_NAME}_mpas.nc" "${UMBRELLA_PREP_CHEM_DATA}"/smoke.init.nc
fi
# 
n_fmc=$(ls "${FMC_INPUTDIR}/fmc_${YYYY}${MM}${DD}"* | wc -l)
if (( n_fmc > 0 )); then
  echo "Have at least some soil moisture information, will interpolate"
    ln -s "${FMC_INPUTDIR}"/* "${DATA}"/
    srun python -u "${SCRIPT}"   \
                    "FMC" \
                    "${DATA}" \
                    "${FMC_INPUTDIR}" \
                    "${FMC_OUTPUTDIR}" \
                    "${INTERP_WEIGHTS_DIR}" \
                    "${YYYY}${MM}${DD}${HH}"
  # Average for ebb2
  ncrcat "${FMC_OUTPUTDIR}"/fmc*"${MESH_NAME}"*nc "${UMBRELLA_PREP_CHEM_DATA}"/fmc.init.nc
  ncks -A -v 10h_dead_fuel_moisture_content "${UMBRELLA_PREP_CHEM_DATA}"/fmc.init.nc "${UMBRELLA_PREP_CHEM_DATA}"/smoke.init.nc
  ncrename -v 10h_dead_fuel_moisture_content,fmc_prev24 "${UMBRELLA_PREP_CHEM_DATA}"/smoke.init.nc
else
  echo "No soil moisture information available, using static value of 0.2"
  ncap2 -O -s 'fmc_prev24=0*frp_prev24+0.2' "${UMBRELLA_PREP_CHEM_DATA}"/smoke.init.nc "${UMBRELLA_PREP_CHEM_DATA}"/smoke.init.nc
fi

#!/usr/bin/env bash
# shellcheck disable=SC2154,SC2153,SC2012,SC2016
# Remove any old files. Needed on reruns: later steps glob smoke.init.retro.*.nc
# (e.g. ncrcat), so leftovers from a previous run would sneak into this cycle
rm -f "${UMBRELLA_PREP_CHEM_DATA}"/smoke.init*nc
rm -f "${DATA}"/smoke.init.retro.*.nc "${DATA}"/bb_pt.stack_groups.init.nc

# RAVE_INPUT is provided by the job card directly
ECO_INPUTDIR=${CHEM_INPUT}/aux/ecoregion/raw/
FMC_INPUTDIR=${CHEM_INPUT}/aux/FMC/raw/${YYYY}/${MM}/

# output directories
RAVE_OUTPUTDIR=${DATA}
ECO_OUTPUTDIR=${DATA}
FMC_OUTPUTDIR=${DATA}

SRUN_PYTHON="srun --exclusive --ntasks=1 --cpus-per-task=1 --mem=0 python -u"
DAYS_SHIFT=0 # default behavior

# Exiting on error if using HWP modulated emissions until implementation:
[[ "${EBB_DCYCLE}" -eq 2 ]] && echo "FATAL ERROR: EBB_DCYCLE = 2 not yet supported. Aborting..." && exit 1

# 1) Calculate the dates for processing which depends on EBB_DCYCLE.
#    All date math is done in epoch seconds (UTC): 'date -d "... + 24 hours"' can
#    misread '+24'/'-24' as a time zone offset
CYCLE_S=$(date -u -d "${CDATE:0:4}-${CDATE:4:2}-${CDATE:6:2} ${CDATE:8:2}:00:00" +%s)

if [[ "${EBB_DCYCLE}" -eq -1 ]]; then
    # Persistence (forecast mode): previous day's fires, labeled with this cycle's
    # dates (--days-shift 1). Never more than 24 h of fire data: forecast hours
    # 0..min(FCST_LENGTH,24). Hours beyond 24 are filled by repeating the first day (step 4)
    NHOURS=$(( FCST_LENGTH < 24 ? FCST_LENGTH : 24 ))
    DAYS_SHIFT=1
    START=$(( CYCLE_S - 86400 ))
else
    # Retro: fires valid at each forecast hour, no shift
    NHOURS=${FCST_LENGTH}
    START=${CYCLE_S}
fi
END=$(( START + NHOURS * 3600 ))
DATE1=$(date -u -d "@${START}" '+%F %T')
DATE2=$(date -u -d "@${END}"   '+%F %T')

# Array of dates to process in current cycle
DATES=()
for (( t=START; t<=END; t+=3600 )); do
    DATES+=( "$(date -u -d "@${t}" '+%F %T')" )
done


# 2) If FIRE_DATASET is NGFS we need to merge 5-min GOES NGFS data into hourly, else 
#    we just go to the vectorization step.
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
    
    # Process hourly files
    MAX_PARALLEL=13; nrun=0
    for DATE in "${DATES[@]}"; do
        NGFS_START=$(date -d "${DATE}" +"%Y-%m-%d_%H:%M:%S")
        ${SRUN_PYTHON} "${NGFS_PROCESSOR_DIR}/process_bysat_NGFS.py" \
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

# 3) Vectorize fire data
TABLE="${FIXrrfs}/chemistry/RAVE/table_vectorize_${FIRE_DATASET,,}.csv"
${SRUN_PYTHON} "${SCRIPT}" \
        --date1         "${DATE1}"          \
        --date2         "${DATE2}"          \
        --pathin        "${FIRE_INPUT}"     \
        --pathout       "${RAVE_OUTPUTDIR}" \
        --table         "${TABLE}"          \
        --dataset       "${FIRE_DATASET}"   \
        --treatmissing  'last'              \
        --days-shift    "${DAYS_SHIFT}"

# 4) Persistence with FCST_LENGTH > 24: repeat the first day for the remaining hours.
#    Each forecast hour uses the same hour of day from the first 24 h, e.g. with
#    FCST_LENGTH=48: hour 25 <- hour 1, hour 26 <- hour 2, ..., hour 48 <- hour 24.
if [[ "${EBB_DCYCLE}" -eq -1 ]] && (( FCST_LENGTH > 24 )); then
    for (( ihour=25; ihour<=FCST_LENGTH; ihour++ )); do
        offset=$(( ihour % 24 == 0 ? 24 : ihour % 24 ))      # 1..24
        src_label=$(date -u -d "@$(( CYCLE_S + offset * 3600 ))" '+%Y-%m-%d_%H.%M.%S')
        dst_label=$(date -u -d "@$(( CYCLE_S + ihour  * 3600 ))" '+%Y-%m-%d_%H.%M.%S')
        src="${RAVE_OUTPUTDIR}/smoke.init.retro.${src_label}.nc"
        dst="${RAVE_OUTPUTDIR}/smoke.init.retro.${dst_label}.nc"
        if [[ ! -s "${src}" ]]; then
            echo "FATAL: ${src} not found, cannot fill forecast hour ${ihour}"; exit 1
        fi
        # cp, not ln: later steps edit each file in place (e.g. its own xtime)
        cp "${src}" "${dst}"
        # Give the copy its own valid time (xtime + Time reference)
        xt=$(date -u -d "@$(( CYCLE_S + ihour * 3600 ))" '+%Y-%m-%d_%H:%M:%S')
        tu=$(date -u -d "@$(( CYCLE_S + ihour * 3600 ))" '+%Y-%m-%d %H:%M:%S')
        ncap2 -O -h -s "xtime(0,0:18)=\"${xt}\"" "${dst}" "${dst}"          # overwrite first 19 chars
        ncatted -O -h -a units,Time,o,c,"seconds since ${tu}" "${dst}"
    done
fi

# Sanity check: one file per forecast hour 0..FCST_LENGTH
nfiles=$(ls "${RAVE_OUTPUTDIR}"/smoke.init.retro.*.nc 2>/dev/null | wc -l)
if (( nfiles != FCST_LENGTH + 1 )); then
    echo "FATAL: expected $(( FCST_LENGTH + 1 )) smoke.init.retro files, found ${nfiles}"; exit 1
fi

# Move the bb_pt.stack_groups.init.nc and smoke files to the main directory:
mv ${DATA}/bb_pt.stack_groups.init.nc   ${UMBRELLA_PREP_CHEM_DATA}
mv ${DATA}/smoke.init*.nc               ${UMBRELLA_PREP_CHEM_DATA}

# In the future we need to add exceptions to support HWP modulated emissions.
# One option is to include that treatment within the python vectorization code that can produce
# a single smoke.init.nc file with the variables needed already calculated.
# Below we are keeping the old treatment commented out just for reference.
# For now let's just exit
exit 1



# # Loop through the hours and link the files so they have the correct filename and variable names 
# # TODO - Update variable names via outside script or within regrid.py -- mapping table?
# for ihour in $(seq 0 "$((FCST_LENGTH))");
# do 
#   current_fcst_time="${current_day} ${HH} + ${ihour} hours"
#   # For persistence 
#   if (( ihour > 0 && ihour % 24 == 0 )); then
#      offset=24
#   else
#      offset=$((ihour % 24))
#   fi
#  
#   if [[ "${EBB_DCYCLE}" == 1 ]]; then
#      # Either NOWcast (1 emission file per current forecast hour) or
#      # Forecasted emissions requiring the previous 24 hours
#      timestr1=$(date +%Y%m%d%H -d "${current_fcst_time}")
#   else
#      # Peristence emissions, only 24 forecasts are possible
#      # Beyond that we need to repeat the emissions
#      timestr1=$(date +%Y%m%d%H -d "${previous_day} ${HH} + ${offset} hours")
#   fi
# 
#   timestr2=$(date +%Y-%m-%d_%H -d "${current_fcst_time}")
#   timestr3=$(date +%Y-%m-%d_%H:00:00 -d "${current_fcst_time}")
#   #
#   EMISFILE="${UMBRELLA_PREP_CHEM_DATA}/smoke.init.retro.${timestr2}.00.00.nc"
#   EMISFILE2="${RAVE_OUTPUTDIR}/${MESH_NAME}-${FIRE_DATASET}-${timestr1}.nc"
#   if [[ -r "${EMISFILE2}" ]]; then
#     ncrename -v .PM25,e_bb_in_smoke_fine "${EMISFILE2}"
#     ncrename -v .FRP_MEAN,frp_in -v FRE,fre_in "${EMISFILE2}"
#     if [[ "${FIRE_DATASET}" != "NGFS" ]]; then
#         ncrename -v .SO2,e_bb_in_so2 "${EMISFILE2}"
#         ncrename -v .CH4,e_bb_in_ch4 "${EMISFILE2}"
#         ncrename -v .PM10,e_bb_in_smoke_coarse "${EMISFILE2}"
#         ncrename -v .CO,e_bb_in_co "${EMISFILE2}"
#         ncrename -v .NH3,e_bb_in_nh3 "${EMISFILE2}"
#         ncrename -v .NOx,e_bb_in_nox "${EMISFILE2}"
#     fi
#     ln -sf "${EMISFILE2}" "${EMISFILE}"
#     ncap2 -O -s 'frp_in=frp_in.ttl($nkwildfire)' -s 'fre_in=fre_in.ttl($nkwildfire)' "${EMISFILE}" "${EMISFILE}"
#   else
#      # Peristence emissions, only 24 forecasts are possible
#      # Beyond that we need to repeat the emissions
#      timestr1=$(date +%Y%m%d%H -d "${previous_day} ${HH} + ${offset} hours")
#   fi
 
#   timestr2=$(date +%Y-%m-%d_%H -d "${current_fcst_time}")
#   timestr3=$(date +%Y-%m-%d_%H:00:00 -d "${current_fcst_time}")
#   #
#   EMISFILE="${UMBRELLA_PREP_CHEM_DATA}/smoke.init.retro.${timestr2}.00.00.nc"
#   EMISFILE2="${RAVE_OUTPUTDIR}/${MESH_NAME}-${FIRE_DATASET}-${timestr1}.nc"
#   if [[ -r "${EMISFILE2}" ]]; then
#     ncrename -v .PM25,e_bb_in_smoke_fine "${EMISFILE2}"
#     ncrename -v .FRP_MEAN,frp_in -v FRE,fre_in "${EMISFILE2}"
#     ncrename -v .SO2,e_bb_in_so2 "${EMISFILE2}"
#     ncrename -v .CH4,e_bb_in_ch4 "${EMISFILE2}"
#     ncrename -v .PM10,e_bb_in_smoke_coarse "${EMISFILE2}"
#     ncrename -v .CO,e_bb_in_co "${EMISFILE2}"
#     ncrename -v .NH3,e_bb_in_nh3 "${EMISFILE2}"
#     ncrename -v .NOx,e_bb_in_nox "${EMISFILE2}"
#     ln -sf "${EMISFILE2}" "${EMISFILE}"
#     ncap2 -O -s 'frp_in=frp_in.ttl($nkwildfire)' -s 'fre_in=fre_in.ttl($nkwildfire)' "${EMISFILE}" "${EMISFILE}"
#   else
#     dummyRAVE=${FIXrrfs}/chemistry/${FIRE_DATASET}/${FIRE_DATASET}.dummy.${MESH_NAME}.nc
#     if [[ -s ${dummyRAVE} ]]; then
#       cp "${dummyRAVE}" "${EMISFILE}"
#     else
#       echo "${dummyRAVE} not found, stop the workflow..."
#       err_exit
#     fi
#   fi
#   # TODO temporary fix until YAML options are built into regriddder
#   ncks -O -6 "${EMISFILE}" "${EMISFILE}"
#   ncks -A -v xtime ./init.nc  "${EMISFILE}"
#   #shellcheck disable=SC2086
#   ncap2 -O -s xtime=\"${timestr3}\" "${EMISFILE}" "${EMISFILE}"  
# done
# 
# #
# #
# echo "Concatenating hourly files for use in forecast mode"
# # Concatenate for ebb2
# nc_vars="frp_in|fre_in|e_bb_in_smoke_fine"
# [[ "${FIRE_DATASET}" == "RAVE" ]] && nc_vars="${nc_vars}|e_bb_in_so2|e_bb_in_ch4|e_bb_in_smoke_coarse|e_bb_in_nh3"
# ncrcat -v "^(${nc_vars})$" "${UMBRELLA_PREP_CHEM_DATA}"/smoke.init.retro.*.00.00.nc "${UMBRELLA_PREP_CHEM_DATA}"/smoke.init.nc
# #
# # Calculate previous 24 hour average HWP
# #
# # TODO - presently hwp and totprcp have constant values
# ncap2 -O -s 'hwp_prev24=0.0*frp_in+30.' -s 'totprcp_prev24=0.0*frp_in+0.1' "${UMBRELLA_PREP_CHEM_DATA}"/smoke.init.nc "${UMBRELLA_PREP_CHEM_DATA}"/smoke.init.nc
# ncrename -v .frp_in,frp_prev24 -v .fre_in,fre_prev24 "${UMBRELLA_PREP_CHEM_DATA}"/smoke.init.nc
# #
# # Emissions to be calculated inside of model
# if [[ ! -r "${ECO_OUTPUTDIR}/ecoregions_${MESH_NAME}_mpas.nc" ]] && [[ -r "${ECO_INPUTDIR}/veg_map.nc" ]]; then
#    echo "Regridding ECO_REGION"
#    srun python -u "${SCRIPT}"   \
#                    "ECOREGION" \
#                    "${DATA}" \
#                    "${ECO_INPUTDIR}" \
#                    "${ECO_OUTPUTDIR}" \
#                    "${INTERP_WEIGHTS_DIR}" \
#                    "${YYYY}${MM}${DD}${HH}"

#   ncks -A -v ecoregion_ID "${ECO_OUTPUTDIR}/ecoregions_${MESH_NAME}_mpas.nc" "${UMBRELLA_PREP_CHEM_DATA}"/smoke.init.nc
# fi
# # 
# n_fmc=$(ls "${FMC_INPUTDIR}/fmc_${YYYY}${MM}${DD}"* | wc -l)
# if (( n_fmc > 0 )); then
#   echo "Have at least some soil moisture information, will interpolate"
#     ln -s "${FMC_INPUTDIR}"/* "${DATA}"/
#     srun python -u "${SCRIPT}"   \
#                     "FMC" \
#                     "${DATA}" \
#                     "${FMC_INPUTDIR}" \
#                     "${FMC_OUTPUTDIR}" \
#                     "${INTERP_WEIGHTS_DIR}" \
#                     "${YYYY}${MM}${DD}${HH}"
#   # Average for ebb2
#   ncrcat "${FMC_OUTPUTDIR}"/fmc*"${MESH_NAME}"*nc "${UMBRELLA_PREP_CHEM_DATA}"/fmc.init.nc
#   ncks -A -v 10h_dead_fuel_moisture_content "${UMBRELLA_PREP_CHEM_DATA}"/fmc.init.nc "${UMBRELLA_PREP_CHEM_DATA}"/smoke.init.nc
#   ncrename -v .10h_dead_fuel_moisture_content,fmc_prev24 "${UMBRELLA_PREP_CHEM_DATA}"/smoke.init.nc
# else
#   echo "No soil moisture information available, using static value of 0.2"
#   ncap2 -O -s 'fmc_prev24=0*frp_prev24+0.2' "${UMBRELLA_PREP_CHEM_DATA}"/smoke.init.nc "${UMBRELLA_PREP_CHEM_DATA}"/smoke.init.nc
# fi
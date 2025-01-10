#!/bin/bash

# Function to clear the screen and position cursor at the top
clear_screen_last_caller_name=""
clear_screen() {
    local caller_name="${FUNCNAME[1]}"

    # Ignore if the previous caller function matches any of the arguements after $1
    # Good to avoid clearing the screen multiple times as part of the same menu tree.
    if [[ "$1" == "ignore" ]]; then
        for arg in "${@:2}"; do
            if [[ "$arg" == "$clear_screen_last_caller_name" ]]; then
                clear_screen_last_caller_name="$caller_name"
                return
            fi
        done
    fi

    # If "force" is specified, clear the screen regardless of the last caller, otherwise, don't clear twice for same caller
    if [[ "$1" = "force" || "$caller_name" != "$clear_screen_last_caller_name" ]]; then
        echo -e "\e[2J\e[H"
        clear_screen_last_caller_name="$caller_name"
    fi
}

# Save the cursor position
save_cursor_position() {
    if [ "$1" == "alt" ]; then
        # echo -en "\e7"
        tput sc
    else
        echo -en "\e[s"
    fi
}
restore_cursor_position() {
    if [ "$1" == "alt" ]; then
        # Restore the cursor position and clear from there to the saved cursor position using the "alt" approach
        # echo -en "\e8\e[2J"
        tput rc
        tput ed
        # Re-save the cursor position
        # echo -en "\e7"
        tput sc
    else
        # Restore the cursor position and clear from there to the end of the screen (default approach)
        echo -en "\e[u\e[J"
        # Re-save the cursor position
        echo -en "\e[s"
    fi

}
# Function to save definitions to the file
update_definitions() {

    # Remove leading and trailing spaces from elements and copy to new arrays
    local new_domains=()
    local new_paths=()
    for domain in "${DOMAINS[@]}"; do
        new_domains+=("\"${domain#"${domain%%[![:space:]]*}"}\"") # trip spaces and add inside double quote
    done
    for path in "${PATHS[@]}"; do
        new_paths+=("\"${path#"${path%%[![:space:]]*}"}\"") # trip spaces and add inside double quote
    done

    # Overwrite the definitions file
    cat <<EOL >"$DEFINITIONS_FILE"
# Definitions

# Indexed arrays for domains and paths
EOL

    if [ ${#new_domains[@]} -eq 0 ]; then
        echo "DOMAINS=()" >>"$DEFINITIONS_FILE"
    else
        echo "DOMAINS=(${new_domains[@]})" >>"$DEFINITIONS_FILE"
    fi

    if [ ${#new_paths[@]} -eq 0 ]; then
        echo "PATHS=()" >>"$DEFINITIONS_FILE"
    else
        echo "PATHS=(${new_paths[@]})" >>"$DEFINITIONS_FILE"
    fi

    # Backup configuration options
    cat <<EOL >>"$DEFINITIONS_FILE"

EOL

    # Update definitions state variables
    update_definitions_state
}
# Function to update the variables that represent the state of our definitions
update_definitions_state() {

    # Check if DOMAINS array is empty
    ARE_DOMAINS_EMPTY=false
    if [ ${#DOMAINS[@]} -eq 0 ]; then
        ARE_DOMAINS_EMPTY=true
    fi

    # Check if rclone is configured by listing remotes
    IS_RCLONE_CONFIGURED=false
    if sudo rclone listremotes --long 2>&1 | grep -qEv 'NOTICE:'; then
        IS_RCLONE_CONFIGURED=true
    fi

    # Check if there are existing backups in the "cron_scripts" directory
    HAS_AUTOMATED_BACKUPS=false
    if [[ -d "$CRON_SCRIPTS_DIR" && -n "$(find "$CRON_SCRIPTS_DIR" -type f)" ]]; then
        HAS_AUTOMATED_BACKUPS=true
    fi

    # Update ARE_DOMAINS_EMPTY based on the value of HAS_AUTOMATED_BACKUPS to indicate automated backup exist, but domains don't
    if [[ $ARE_DOMAINS_EMPTY == true && $HAS_AUTOMATED_BACKUPS == true ]]; then
        ARE_DOMAINS_EMPTY=-1
    fi
}

# Function to add or update domain and user
add_domain() {

    clear_screen "force"

    read -p "$(echo -e "${BOLD}${BLUE}Enter a domain${RESET} ${BLUE}( or q to go back ): ${RESET}")" domain

    if [ $domain == "q" ]; then
        manage_domains
        return
    fi

    # Clean and validate the domain
    local sanitized_domain=$(echo "$domain" | sed -e 's|^https://||' -e 's|^http://||' -e 's|^www\.||' -e 's|/.*$||')
    local domain_pattern="^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$"
    if [[ ! "$sanitized_domain" =~ $domain_pattern ]]; then
        clear_screen "force"
        echo -e "${RED}"${domain}" is not a valid domain.${RESET}"
        return
    fi

    # Check if the domain already exists in the DOMAINS array
    local duplicate=false
    for existing_domain in "${DOMAINS[@]}"; do
        if [ "$existing_domain" == "$sanitized_domain" ]; then
            duplicate=true
            break
        fi
    done
    # If the domain is already added, show an error
    if [ "$duplicate" == true ]; then
        clear_screen "force"
        echo -e "${RED}Domain $sanitized_domain is already in the list.${RESET}"
        return
    fi

    # Get the WordPress installation dir for that domain
    read -p "$(echo -e "${BOLD}${BLUE}Enter the WordPress installation's full path for $sanitized_domain${RESET} ${BLUE}( or q to go back ): ${RESET}")" path

    if [ $path == "q" ]; then
        add_domain
        return
    fi

    # Make sure the path always has a leading slash
    if [[ ! "$path" == /* ]]; then
        path="/$path"
    fi

    # Remove any trailing slash
    path="${path%/}"

    # Check for WordPress installation in different possible locations
    local wp_path=""

    # Check WordOps structure first (wp-config.php in parent, files in htdocs)
    if [ -f "$path/wp-config.php" ] && [ -d "$path/htdocs" ]; then
        wp_path="$path/htdocs"
    # Check if path points to htdocs directory
    elif [ -f "${path%/htdocs}/wp-config.php" ] && [ -d "$path" ]; then
        wp_path="$path"
    # Check standard structure (everything in same directory)
    elif [ -f "$path/wp-config.php" ]; then
        wp_path="$path"
    else
        # No WordPress installation found
        clear_screen "force"
        echo -e "${RED}We could not find a WordPress installation under $path ${RESET}"
        return
    fi

    # WordPress installation exists for this domain, let's append it to the array
    DOMAINS+=("$sanitized_domain")
    PATHS+=("$wp_path") # Store the path to WordPress files
    update_definitions   # Save definitions after each addition
    clear_screen "force"
    echo -e "${GREEN}Domain $sanitized_domain added successfully.${RESET}"
}

# Function to delete domain and path
delete_domain() {

    clear_screen "force"

    # Show a list of existing domains
    echo -e "${BOLD}The following is a list of the domains/sites available for deletion:${RESET}"
    for ((i = 0; i < ${#DOMAINS[@]}; i++)); do
        domain="${DOMAINS[$i]}"
        echo -e "- $domain"
    done

    # Ask user to type the domain they want to delete
    echo ""
    echo -e "${BOLD}${YELLOW}Note: ${RESET}${YELLOW}the automated backups created for the selected domain will NOT be effected.${RESET}"
    read -p "$(echo -e "${BOLD}${BLUE}Enter a domain to delete${RESET} ${BLUE}( or q to go back ): ${RESET}")" domain_to_delete

    if [ $domain_to_delete == "q" ]; then
        manage_domains
        return
    fi

    # Attempt to delete the domain from our list, and keep track
    local deleted=false
    local new_domains=()
    local new_paths=()

    for ((i = 0; i < ${#DOMAINS[@]}; i++)); do
        if [ "${DOMAINS[$i]}" != "$domain_to_delete" ]; then
            new_domains+=("${DOMAINS[$i]}")
            new_paths+=("${PATHS[$i]}")
        else
            deleted=true
        fi
    done

    # Run processes asscoaited with deletion, or raise an error
    if [ $deleted == true ]; then
        # Update the DOMAINS and PATHS arrays with the new values
        DOMAINS=("${new_domains[@]}")
        PATHS=("${new_paths[@]}")

        clear_screen "force"
        # Show success message
        echo -e "${GREEN}Domain $domain_to_delete has been deleted successfully.${RESET}"
        # Save definitions after each deletion
        update_definitions
    else

        clear_screen "force"
        # Show an error
        echo -e "${RED}Invalid choice. Domain $domain_to_delete is not in the list.${RESET}"
    fi

}

# Function to allow the management of domains and path ( view, add, delete )
manage_domains() {
    # If there are no existing domains/sites, fall back to the 'add_domain' function
    if [[ $ARE_DOMAINS_EMPTY == true || $ARE_DOMAINS_EMPTY == -1 ]]; then
        add_domain
    fi

    # Clear screen and show the site management menu
    clear_screen

    while true; do
        # Add a title
        echo -e "${BOLD}${UNDERLINE}Manage sites/domains${RESET}"
        # Show list of options
        local original_ps3="$PS3" # Save the original PS3 value
        PS3="$(echo -e "${BOLD}${BLUE}Type the desired option number to continue: ${RESET}")"
        options=("View existing domains/sites" "Add a new domain/site" "Delete an existing domain/site" "Return to the previous menu")
        select choice in "${options[@]}"; do
            case "$choice" in
            "View existing domains/sites")
                clear_screen "force"
                echo -e "${BOLD}The following is a list of the domain you've added:${RESET}"
                for ((i = 0; i < ${#DOMAINS[@]}; i++)); do
                    domain="${DOMAINS[$i]}"
                    path="${PATHS[$i]}"
                    echo -e "- ${BOLD}Domain:${RESET} $domain,  ${BOLD}Path:${RESET} $path"
                done
                echo ""
                ;;
            "Add a new domain/site")
                add_domain
                ;;
            "Delete an existing domain/site")
                delete_domain
                # Return to the main menu if there are no domains available
                if [[ $ARE_DOMAINS_EMPTY == true || $ARE_DOMAINS_EMPTY == -1 ]]; then
                    return
                fi
                ;;
            "Return to the previous menu")
                clear_screen "force"
                return
                ;;
            *)
                clear_screen "force"
                echo -e "${RED}Invalid choice. Please select a valid option.${RESET}"
                ;;
            esac
            break
        done
        PS3="$original_ps3" # Restore the original PS3 value
    done

}

# A wrapper function that triggers `rclone config` to allow using to create new remotes, edit existing..etc
configure_rclone() {

    clear_screen

    local configure_rclone=false
    # If there is an existing list of remotes, allow user to decide whether to configure rclone or not
    if sudo rclone listremotes --long 2>&1 | grep -qEv 'NOTICE:'; then
        # Add a title
        echo -e "${BOLD}${UNDERLINE}Re-configure rclone${RESET}"

        read -p "$(echo -e "${BOLD}${BLUE}Rclone has existing remotes, would you like to re-configure it (y/n): ${RESET}")" config
        if [ $config == "y" ] || [ $config == "yes" ]; then
            # Configure rclone
            configure_rclone=true
        fi
    else
        # Add a title
        echo -e "${BOLD}${UNDERLINE}Configure rclone${RESET}"

        # Configure rclone
        configure_rclone=true
    fi

    if [ $configure_rclone == true ]; then

        # Clear screen
        clear_screen "force"
        # Show a message
        echo -e "${YELLOW}Initializing rclone configuration ...${RESET}"
        echo ""
        # Start the configuration
        sudo rclone config
    fi

    # Clear screen
    clear_screen "force"

    # Update definitions state variables
    update_definitions_state
}

# Function to collect the backup settings from the user
collect_backup_settings() {

    echo -e "${BOLD}${YELLOW}Step 1: ${RESET}${YELLOW}configure your backup settings.${RESET}"
    echo ""

    # Save the original PS3 value
    local original_ps3="$PS3"

    # Collect the target domain/site
    PS3="$(echo -e "${BOLD}${BLUE}Select the target domain for this backup: ${RESET}")"
    select BACKUP_DOMAIN in "${DOMAINS[@]}" "none"; do
        if [ "$BACKUP_DOMAIN" == "none" ]; then
            return
        elif [ -n "$BACKUP_DOMAIN" ]; then
            break
        else
            echo -e "${RED}Invalid option. Please select a valid number.${RESET}"
        fi
    done
    PS3="$original_ps3" # Restore the original PS3 value

    # Collect frequency preference
    PS3="$(echo -e "${BOLD}${BLUE}Choose backup frequency: ${RESET}")"
    select frequency in "daily" "weekly" "monthly" "none"; do
        case $frequency in
        daily | weekly | monthly)
            BACKUP_FREQUENCY="$frequency"
            break
            ;;
        none)
            return
            ;;
        *)
            echo -e "${RED}Invalid option. Please select a valid frequency.${RESET}"
            ;;
        esac
    done
    PS3="$original_ps3" # Restore the original PS3 value

    # Collect backup time preference
    PS3="$(echo -e "${BOLD}${BLUE}Choose backup time: ${RESET}")"
    options=("01:00" "02:00" "03:00" "04:00" "05:00" "06:00" "07:00" "08:00" "09:00" "10:00" "11:00" "12:00" "13:00" "14:00" "15:00" "16:00" "17:00" "18:00" "19:00" "20:00" "21:00" "22:00" "23:00" "00:00" "none")
    select time in "${options[@]}"; do
        case $time in
        "01:00" | "02:00" | "03:00" | "04:00" | "05:00" | "06:00" | "07:00" | "08:00" | "09:00" | "10:00" | "11:00" | "12:00" | "13:00" | "14:00" | "15:00" | "16:00" | "17:00" | "18:00" | "19:00" | "20:00" | "21:00" | "22:00" | "23:00" | "00:00")
            BACKUP_TIME="$time"
            break
            ;;
        "none")
            return
            ;;
        *)
            echo -e "${RED}Invalid option. Please select a valid time.${RESET}"
            ;;
        esac
    done
    PS3="$original_ps3" # Restore the original PS3 value

    # Collect retention period preference
    PS3="$(echo -e "${BOLD}${BLUE}Choose a retention period option: ${RESET}")"
    select retention in "3 days" "7 days" "30 days" "90 days" "180 days" "none"; do
        case $retention in
        "3 days" | "7 days" | "30 days" | "90 days" | "180 days")
            RETENTION_PERIOD="${retention%% *}" # Extract the numeric part
            break
            ;;
        none)
            return
            ;;
        *)
            echo -e "${RED}Invalid option. Please select a valid retention period.${RESET}"
            ;;
        esac
    done
    PS3="$original_ps3" # Restore the original PS3 value

    # Collect excluded folders
    read -p "$(echo -e "${BOLD}${BLUE}Enter folders to exclude (comma-separated eg; wp-admin, wp-includes; or leave empty for none): ${RESET}")" EXCLUDED_ITEMS

    # Collect backup type
    if [ $RESTIC_AVAILABLE == true ]; then
        PS3="$(echo -e "${BOLD}${BLUE}Choose backup type: ${RESET}")"
        select type in "full" "incremental"; do
            case $type in
            full | incremental)
                BACKUP_TYPE="$type"
                break
                ;;
            *)
                echo -e "${RED}Invalid option. Please select a valid type.${RESET}"
                ;;
            esac
        done
    else
        BACKUP_TYPE="full"
    fi

    # Collect restic password
    if [ $BACKUP_TYPE == "incremental" ]; then
        echo ""
        echo -e "${YELLOW}A password is required for incremental backups.${RESET}"
        echo -e "${BOLD}${YELLOW}Note 1:${RESET} ${YELLOW}The password is required by restic to take and restore backups.${RESET}"
        echo -e "${BOLD}${YELLOW}Note 2:${RESET} ${YELLOW}The Password will be saved in plain-text inside the backup script for automation.${RESET}"
        echo -e "${BOLD}${YELLOW}Note 3:${RESET} ${YELLOW}If the backup script is deleted, the password record will be lost.${RESET}"
        echo -e "${BOLD}${YELLOW}Note 4:${RESET} ${YELLOW}Make sure to remember your password, if it's lost/forgotten, the incremental backups cannot be restored anywhere.${RESET}"
        echo ""

        while true; do

            read -s -p "$(echo -e "${BOLD}${BLUE}Enter your password: ${RESET}")" BACKUP_PASS
            echo ""
            read -s -p "$(echo -e "${BOLD}${BLUE}Confirm your password: ${RESET}")" BACKUP_CONFIRM_PASS
            echo ""

            if [ "$BACKUP_PASS" == "$BACKUP_CONFIRM_PASS" ]; then
                break
            else
                echo -e "${RED}Passwords do not match. Please try again.${RESET}"
            fi
        done
    fi

    # Collect the destination folder path
    echo -e "${BLUE}- if using object based storage (eg; AWS S3, Google Cloud Storage..etc), the backup location should start with the 'bucket' name (eg; bucket/path/to/dir)${RESET}"
    echo -e "${BLUE}- If using SFTP/FTP based storage, use the full path to your backup directory (eg; /home/user/backup_folder)${RESET}"
    read -p "$(echo -e "${BOLD}${BLUE}Enter your backup location: ${RESET}")" REMOTE_BACKUP_LOCATION

    # If `$REMOTE_BACKUP_LOCATION` has a trailing slash, remove it
    if [[ -n "$REMOTE_BACKUP_LOCATION" && "$REMOTE_BACKUP_LOCATION" == */ ]]; then
        REMOTE_BACKUP_LOCATION="${REMOTE_BACKUP_LOCATION%/}"
    fi

    # Make sure all required settings are available, otherwise, re-collect them
    if [[ -z "$BACKUP_DOMAIN" || -z "$BACKUP_FREQUENCY" || -z "$BACKUP_TIME" || -z "$RETENTION_PERIOD" || -z "$BACKUP_TYPE" ]]; then

        clear_screen "force"
        echo -e "${RED}Something is missing, please select your preferences again.${RESET}"
        collect_backup_settings
        return
    fi

    # Ask the user to confirm their settings before proceeding
    echo ""
    echo -e "${YELLOW}Your current backup configurations:${RESET}"
    echo -e "${BOLD}Backup Site:${RESET} $BACKUP_DOMAIN"
    echo -e "${BOLD}Backup Frequency:${RESET} $BACKUP_FREQUENCY"
    echo -e "${BOLD}Backup Time:${RESET} $BACKUP_TIME"
    echo -e "${BOLD}Retention Period:${RESET} $RETENTION_PERIOD days"
    echo -e "${BOLD}Excluded Locations:${RESET} $EXCLUDED_ITEMS"
    echo -e "${BOLD}Remote Backup Location:${RESET} $REMOTE_BACKUP_LOCATION"
    echo -e "${BOLD}Remote Backup Type:${RESET} $BACKUP_TYPE"

    read -p "$(echo -e "${BOLD}${BLUE}Are you sure you want to proceed with the above configurations? (y/n): ${RESET}")" confirm
    if [[ $confirm != "y" && $confirm != "yes" ]]; then
        clear_screen "force"
        echo -e "${YELLOW}Please select your preferences again.${RESET}"
        collect_backup_settings
        return
    fi

}

generate_backup_script() {

    clear_screen

    # Add a title
    if [ $HAS_AUTOMATED_BACKUPS == false ]; then
        echo -e "${BOLD}${UNDERLINE}Create an automated backup${RESET}"
    else
        echo -e "${BOLD}${UNDERLINE}Manage backups > Create a new automated backup${RESET}"
    fi

    # Collect backup settings from user
    collect_backup_settings

    # Extract the collected backup settings from the `$backup_settings` array
    local backup_domain="${BACKUP_DOMAIN}"
    local backup_path=""
    local backup_frequency="${BACKUP_FREQUENCY}"
    local backup_time="${BACKUP_TIME}"
    local retention_period="${RETENTION_PERIOD}"
    local excluded_items="${EXCLUDED_ITEMS}"
    local remote_backup_location="${REMOTE_BACKUP_LOCATION}/"
    local remote_backup_type="${BACKUP_TYPE}"
    local restic_password=""
    local rclone_remote_name=""
    local rclone_remote_valid=false

    # Pull restic password if an incremental backup is defined
    if [ $remote_backup_type == "incremental" ]; then
        restic_password="${BACKUP_PASS}"
    fi

    # Validate backup_domain
    if [[ ! " ${DOMAINS[@]} " =~ " $backup_domain " ]]; then
        clear_screen "force"
        echo -e "${RED}A valid domain must be selected from the available options.${RESET}"
        return
    else
        # If the domain is valid, let populate the backup path
        for ((i = 0; i < ${#DOMAINS[@]}; i++)); do
            current_domain="${DOMAINS[$i]}"
            current_path="${PATHS[$i]}"
            if [ "$current_domain" == "$backup_domain" ]; then
                backup_path=$current_path
            fi
        done
    fi

    # Validate and sanitize backup_frequency
    if [ -z "$backup_frequency" ] || [[ ! "$backup_frequency" =~ ^(daily|weekly|monthly)$ ]]; then
        clear_screen "force"
        echo -e "${RED}A valid frequency must be selected from the available options.${RESET}"
        return
    fi

    # Validate backup_time
    if [ -z "$backup_time" ] || [[ ! "$backup_time" =~ ^[0-9]{2}:[0-9]{2}$ ]]; then
        clear_screen "force"
        echo -e "${RED}A valid backup time must selected from the available options.${RESET}"
        return
    else
        # Convert the user-provided time to the appropriate cron format
        IFS=: read -r cron_hour cron_minute <<<"$backup_time"
    fi

    # Validate retention_period
    if [ -z "$retention_period" ] || [[ ! "$retention_period" =~ ^(3|7|30|90|180)$ ]]; then
        clear_screen "force"
        echo -e "${RED}A valid retention period must selected from the available options.${RESET}"
        return
    fi

    # Create a cron expression based on the frequency and backup time
    case "$backup_frequency" in
    daily)
        cron_expression="$cron_minute $cron_hour * * *"
        ;;
    weekly)
        cron_expression="$cron_minute $cron_hour * * 0" # 0 represents Sunday, adjust as needed
        ;;
    monthly)
        cron_expression="$cron_minute $cron_hour 1 * *" # 1 represents first day of the month
        ;;
    *)
        # Handle invalid or unsupported frequency here
        echo -e "${RED}Invalid or unsupported frequency: $backup_frequency${RESET}"
        exit 1
        ;;
    esac

    # Prepare excludes by breaking the $excluded_items variable by comma and format based on backup type
    excludes=""
    if [ -n "$excluded_items" ]; then
        IFS=',' read -ra excluded_items_array <<<"$excluded_items"
        for item in "${excluded_items_array[@]}"; do
            # Remove leading and trailing spaces
            item=$(echo "$item" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
            # Check if the item exists under the backup_domain path
            if [ -e "${backup_path}/${item}" ]; then
                # Wrap the item in double quotes and add it to excludes
                if [ $remote_backup_type == "incremental" ]; then
                    excludes+=" --exclude=\"${backup_path}/${item}\""
                else
                    excludes+=" --exclude=\"${item}\""
                fi

            else
                echo -e "${YELLOW}Warning: excluded location '${item}' does not exist under '${backup_path}'. Skipping...${RESET}"
            fi
        done
    fi

    clear_screen "force"
    echo -e "${BOLD}${YELLOW}Step 2: ${RESET}${YELLOW}select the rclone's remote you'd like to use for this backup.${RESET}"
    echo ""

    # Get comma seperated list of remotes to give to the user as examples
    local remotes_list=$(sudo rclone listremotes --long | awk -F ':' '{print $1}' | tr '\n' ', ')
    remotes_list="${remotes_list%,}"

    # Show available remotes
    echo -e "${BOLD}Available rclone remotes:${RESET}"
    sudo rclone listremotes --long

    # Use a while loop to make sure the user is prompted again if they made a mistake
    while true; do

        read -p "$(echo -e "${BOLD}${BLUE}Type the name of one of the available remotes as your backup destination (eg; ${remotes_list}): ${RESET}")" rclone_remote_name

        # Check if the entered remote name exists
        if rclone listremotes | grep -q "${rclone_remote_name}:"; then
            break # Remote name is valid, exit the loop
        else
            echo -e "${YELLOW}The remote you entered doesn't exist, please try again.${RESET}"
        fi
    done

    # Validate the rclone remote by writing a test file
    while [ $rclone_remote_valid == false ]; do
        sudo touch wpali.com.txt >/dev/null 2>&1
        # Run the rclone copy command and capture its exit code
        sudo rclone copy wpali.com.txt "${rclone_remote_name}":"${remote_backup_location}"
        exit_code=$?

        # Confirm the file has been created successfully on remote server
        if [ $exit_code -eq 0 ]; then
            # Get the rclone remote name that we'll use for the back up with this cron job
            echo ""
            echo -e "${GREEN}We have created a test file on your remote location.${RESET}"
            echo -e "Please go to ${BOLD}"$remote_backup_location"${RESET} on your remote server and check if this file ${BOLD}"wpali.com.txt"${RESET} exists."
            echo ""
            read -p "$(echo -e "${BOLD}${BLUE}Do you confirm that the test file has been created succesfully on your remote server? (y/n): ${RESET}")" rclone_remote_push_success

            if [[ -n "$rclone_remote_push_success" && ("$rclone_remote_push_success" == "y" || "$rclone_remote_push_success" == "yes") ]]; then
                # Copy was successful
                rclone_remote_valid=true
                # Delete leftovers
                sudo rm wpali.com.txt
                sudo rclone delete "${rclone_remote_name}":"${remote_backup_location}wpali.com.txt"
            fi
        else
            # Copy failed, display relevant errors
            echo -e "${RED}rclone copy failed with exit code $exit_code${RESET}"
            break
        fi
    done

    # Prepare the backup script and cron job based on frequency, time and the other options.
    if [ $rclone_remote_valid == true ]; then

        # Check if the cron scripts directory exists, and create it if it doesn't
        if [ ! -d "$CRON_SCRIPTS_DIR" ]; then
            mkdir -p "$CRON_SCRIPTS_DIR"
        fi

        # Generate a unique name for the backup script based on the frequency and time
        local creation_date=$(date +'%Y-%m-%d %H:%M:%S')
        local script_prefix=$(echo -n "$creation_date-$backup_domain-$cron_expression-$retention_period-$remote_backup_location-$rclone_remote_name-$remote_backup_type" | md5sum | awk '{print $1}') # used to prefix the backup script
        local script_name="${script_prefix}_${backup_domain//./-}_${backup_time//:/-}_${backup_frequency}_to_${rclone_remote_name}"
        local script_path="$CRON_SCRIPTS_DIR/$script_name"
        local script_hash=$(echo -n "$script_name" | md5sum | awk '{print $1}') # Use to prefix backups

        # Check if the file exists
        if [ -e "$script_path" ]; then
            echo -e "${RED}Duplicate detected, this backup could not be created.${RESET}"
            return
        fi

        # Initialize restic if this is an incremental backup
        if [ $remote_backup_type == "incremental" ]; then
            # Check if a restic repository already exists in the remote location
            local restic_remote_config_output=$(sudo RESTIC_PASSWORD="${restic_password}" restic -r "rclone:${rclone_remote_name}:${remote_backup_location}" cat config 2>&1)
            if echo "$restic_remote_config_output" | grep -q "Is there a repository at the following location"; then

                echo ""
                echo -e "${YELLOW}Initializing remote repository ...${RESET}"
                echo ""

                # If there are no errors, initialize the repo
                sudo RESTIC_PASSWORD="${restic_password}" restic -r "rclone:${rclone_remote_name}:${remote_backup_location}" init
                # Check the exit status of the previous command
                if [ $? -ne 0 ]; then
                    # The restic init command failed, we'll bail out to avoid creating a non-valid backup script
                    clear_screen "force"
                    echo -e "${RED}Restic repository initilization failed.${RESET}"
                    echo ""
                    return
                fi
            else
                # If a repository does not exist, restic will return a non-zero exit code
                clear_screen "force"
                echo -e "${RED}This incremental backup could not be created. Duplicate found, or other error.${RESET}"
                echo ""
                return
            fi

        fi
        # Add the starting content for the backup script (eg; variables..etc)
        cat <<EOF >"$script_path"
#!/bin/bash

# Define the call type, whether it's a pre-restore backup, or default backup
if [ \$# -ge 1 ]; then
    call_type=\$1
else
    call_type="backup"
fi

# Exit script on error, only if this is not a pre-restore backup
if [ \${call_type} != "restore" ]; then
    set -e
fi

tmp_path=$TMP_DIR

# Check if the tmp folder exists, and if not, create it
if [ ! -d "\${tmp_path}" ]; then
    sudo mkdir -p "\${tmp_path}"
fi

# Find and delete any 'tar.gz.tmp' or 'sql' files that are older than 48 hours ( failed backups )
sudo find "\${tmp_path}" -type f -name "*.tar.gz.tmp" -mmin +2880 -exec rm {} \;
sudo find "\${tmp_path}" -type f -name "*.sql" -mmin +2880 -exec rm {} \;

# Make sure out logs files doesn't get too big
if [ -f "$LOG_FILE" ]; then
    # Get the current size of the log file in bytes
    log_file_size=\$(stat -c %s "$LOG_FILE")
    log_file_max_size=1048576 # 1MB

    # Check if the log file size exceeds the maximum size ( 1048576 == 1MB )
    if [ "\${log_file_size}" -gt "\${log_file_max_size}" ]; then
        # Truncate the log file to the maximum size
        tail -c "\${log_file_max_size}" "$LOG_FILE" > "$LOG_FILE.tmp"
        mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi
fi

# Save all errors automatically in our logs file
exec >> "$LOG_FILE" 2>&1

# Prepare main variables
type="${remote_backup_type}"
hash="${script_hash}"
creation_date="${creation_date}"
cron_expression="${cron_expression}"
domain="${backup_domain}"
domain_path="${backup_path}"
retention_period=${retention_period}
rclone_remote="${rclone_remote_name}"
remote_backup_location="${remote_backup_location}"
timestamp=\$(date +'%Y-%m-%d %H:%M:%S')
backup_date=\$(date +'%d-%m-%Y_%H-%M')

echo "[\${timestamp}] BACK UP STARTED (\${type}): Performing $backup_time $backup_frequency backup for '\${domain}'" >> "$LOG_FILE"
echo "[\${timestamp}] - Exporting database" >> "$LOG_FILE"

EOF

        # Append to the script based on the backup type
        if [ $remote_backup_type == "incremental" ]; then
            # Add the necessary commands for incremental backups (append to file, note >>)
            cat <<EOF >>"$script_path"
# Get the wp installation folder owner and their home directory
wp_owner=\$(sudo stat -c "%U" \${domain_path})

# Get the database name and construct the db backup file name and path
# Note that we are using sudo to run wp cli commands as "wp_owner" to avoid permissions complications
db_name=\$(sudo -u "\${wp_owner}" -s -- wp config get DB_NAME --path="\${domain_path}")
db_filename=\${hash}_\${domain//./_}_\${db_name}_incremental.sql
# We'll export the database and move it to our current directory as a 'tmp' file
sudo -u "\${wp_owner}" -s -- wp db export "\${domain_path}/\${db_filename}" --path="\${domain_path}"

restic_password=${restic_password}

echo "[\${timestamp}] - Sending the backup to 'rclone' "\${rclone_remote}" remote  using 'restic'" >>"$LOG_FILE"

# Use restic to save a new backup to rclone remote
if [ \${call_type} == "restore" ]; then
    # We will backup the whole folder when it's a pre-restore backup ( no excludes )
    sudo RESTIC_PASSWORD="\${restic_password}" restic -q -r "rclone:\${rclone_remote}:\${remote_backup_location}" backup "\$domain_path/"
else
    sudo RESTIC_PASSWORD="\${restic_password}" restic -q -r "rclone:\${rclone_remote}:\${remote_backup_location}" backup "\$domain_path/" ${excludes}
fi

echo "[\${timestamp}] - backup sent to the remote location successfully" >>"$LOG_FILE"
echo "[\${timestamp}] - Delete the internally generated backup files to free space" >>"$LOG_FILE"

# Delete the generated database file
sudo rm "\${domain_path}/\${db_filename}"

echo "[\${timestamp}] - Delete backups older than \${retention_period} days from 'rclone' "\${rclone_remote}" remote using 'restic'" >>"$LOG_FILE"

# Delete old backups from remote ( retention logic )
sudo RESTIC_PASSWORD="\${restic_password}" restic -q -r "rclone:\${rclone_remote}:\${remote_backup_location}" forget --keep-within "\${retention_period}d" --prune

EOF

        else
            # Add the necessary commands for full backups (append to file, note >>)
            cat <<EOF >>"$script_path"

# Get the wp installation folder owner
wp_owner=\$(sudo stat -c "%U" \${domain_path})

# Use a dedicated temp directory for database backups
wp_owner_directory="/tmp/wp_db_backup"

echo "[\${timestamp}] - WP folder owner found: '\${wp_owner}'" >> "$LOG_FILE"
echo "[\${timestamp}] - Using temp directory: '\${wp_owner_directory}'" >> "$LOG_FILE"

# Create tmp directory with proper permissions if it doesn't exist
if [ ! -d "\${wp_owner_directory}" ]; then
    sudo mkdir -p "\${wp_owner_directory}"
    sudo chown \${wp_owner}:\${wp_owner} "\${wp_owner_directory}"
    sudo chmod 755 "\${wp_owner_directory}"
fi

# Get wp-config.php location (one level up from domain_path for WordOps)
wp_config_path="\${domain_path}"
if [[ "\${domain_path}" == */htdocs ]]; then
    wp_config_path="\${domain_path%/htdocs}"
fi

# Get the database name and construct the db backup file name and path
db_name=\$(sudo -u "\${wp_owner}" -s -- wp config get DB_NAME --path="\${domain_path}")
db_filename=\${hash}_\${domain//./_}_\${db_name}_\${backup_date}.sql

# Export the database with proper permissions
sudo -u "\${wp_owner}" -s -- wp db export "\${wp_owner_directory}/\${db_filename}" --path="\${domain_path}"

if [ \${call_type} == "restore" ]; then
    echo "[\${timestamp}] - Generating pre-restore backup archive" >> "$LOG_FILE"
    backup_filename=\${tmp_path}/\${hash}_\${domain//./-}_\${backup_date}-pre-restore.tar.gz
else
    echo "[\${timestamp}] - Generating backup archive" >> "$LOG_FILE"
    backup_filename=\${tmp_path}/\${hash}_\${domain//./-}_\${backup_date}.tar.gz
fi

# --- Backup Logic ---

# Prepare the backup file (compress the target site and the previously exported database)
echo "[\${timestamp}] - Attempting direct tar backup" >> "$LOG_FILE"

backup_success=false

if sudo test "\${call_type}" = "restore"; then
    # Try direct tar for pre-restore backup first
    if sudo tar --warning=no-file-changed --transform 's,^\./,,' -czf "\${backup_filename}.tmp" -C "\${domain_path}/" . -C "\${wp_owner_directory}/" "\${db_filename}" 2>> "$LOG_FILE"; then
        backup_success=true
        echo "[\${timestamp}] - Direct tar backup successful" >> "$LOG_FILE"
    else
        echo "[\${timestamp}] - Direct tar backup failed, trying alternative method" >> "$LOG_FILE"
    fi
else
    # Try direct tar with excludes first
    if sudo tar --warning=no-file-changed --transform 's,^\./,,' $excludes -czf "\${backup_filename}.tmp" -C "\${domain_path}/" . -C "\${wp_owner_directory}/" "\${db_filename}" 2>> "$LOG_FILE"; then
        backup_success=true
        echo "[\${timestamp}] - Direct tar backup successful" >> "$LOG_FILE"
    else
        echo "[\${timestamp}] - Direct tar backup failed, trying alternative method" >> "$LOG_FILE"
    fi
fi

# If direct tar failed, try cp method
if [ "$backup_success" = false ]; then
    # Create temporary directory for cp method
    tmp_backup_dir="\${wp_owner_directory}/tmp_backup_\${backup_date}"
    
    # Check available space before copying
    required_space=$(sudo du -sb "${domain_path}" | cut -f1)
    available_space=$(sudo df -B1 "${wp_owner_directory}" | awk 'NR==2 {print $4}')
    
    if [ "$available_space" -gt "$((required_space * 2))" ]; then
        echo "[\${timestamp}] - Sufficient space available for cp method" >> "$LOG_FILE"
        
        # Create temp directory and copy files
        sudo mkdir -p "${tmp_backup_dir}"
        
        if sudo test "\${call_type}" = "restore"; then
            sudo cp -a "\${domain_path}/." "\${tmp_backup_dir}/"
        else
            sudo cp -a "\${domain_path}/." "\${tmp_backup_dir}/"
            # Apply excludes by removing excluded files/directories
            for exclude in $excludes; do
                exclude_path=$(echo "$exclude" | sed 's/--exclude=//')
                sudo rm -rf "\${tmp_backup_dir}/\${exclude_path}"
            done
        fi
        
        # Try tar on the copied files
        if sudo tar -czf "\${backup_filename}.tmp" -C "\${tmp_backup_dir}" . -C "\${wp_owner_directory}/" "\${db_filename}" 2>> "$LOG_FILE"; then
            backup_success=true
            echo "[\${timestamp}] - Backup successful using cp method" >> "$LOG_FILE"
        fi
        
        # Clean up temp directory
        sudo rm -rf "${tmp_backup_dir}"
    else
        echo "[\${timestamp}] - Insufficient space for cp method" >> "$LOG_FILE"
    fi
fi

if [ "$backup_success" = false ]; then
    echo "[\${timestamp}] ERROR: All backup methods failed" >> "$LOG_FILE"
    # Cleanup any temporary files
    sudo rm -f "\${backup_filename}.tmp"
    sudo rm -f "\${wp_owner_directory}/\${db_filename}"
    exit 1
fi

# Rename the temporary backup file to the actual name to indicate that the compression completed
sudo mv "\${backup_filename}.tmp" "\${backup_filename}"

# --- End Backup Logic ---

echo "[\${timestamp}] - backup archive generated: "\${backup_filename}"" >> "$LOG_FILE"
echo "[\${timestamp}] - Sending the backup file to remote location "\${rclone_remote}" using rclone" >> "$LOG_FILE"

# Copy the generated backup to the remote location using rclone
sudo rclone copy \$backup_filename \${rclone_remote}:\${remote_backup_location}

echo "[\${timestamp}] - backup file sent to the remote location successfully" >> "$LOG_FILE"
echo "[\${timestamp}] - Delete the internally generated backup files to free space" >> "$LOG_FILE"

# Delete the generated backup archive and database
sudo rm \${backup_filename}
sudo rm \${wp_owner_directory}/\${db_filename}

echo "[\${timestamp}] - Delete backups older than \${retention_period} days from remote location "\${rclone_remote}" using rclone" >> "$LOG_FILE"

# Delete old backups from remote ( retention logic )
sudo rclone delete --min-age \${retention_period}d "\${rclone_remote}":"\${remote_backup_location}"

EOF
        fi

        # Add the final content of the script file (append to file, note >>)
        cat <<EOF >>"$script_path"
echo "[\${timestamp}] BACK UP FINISHED (\${type}): $backup_frequency backup for \${domain} has completed successfully" >> "$LOG_FILE"

# Make sure to close the log file when done
exec 3>&-
EOF

        # Give the script the right permissions ( only owner can read/write/execute )
        sudo chmod 700 "$script_path"
        # Run the script to take the initial backup in the background
        sudo -b bash "$script_path" >/dev/null 2>&1
        # Create our cron file if it doesn't already exist, and give it correct permissions
        if [ ! -f "$CRON_FILE" ]; then
            sudo touch "$CRON_FILE"     # Create the cron file
            sudo chmod 644 "$CRON_FILE" # Ensure the file has the correct permissions
        fi
        # Create the cron file with the necessary cron job
        echo "$cron_expression root /bin/bash $PWD/$script_path" >>"$CRON_FILE"
        # Show success message
        clear_screen "force"
        echo -e "${BOLD}${GREEN}Your automated backup for $backup_domain has been created successfully.${RESET}"
        echo -e "${GREEN}An initial backup is running the background.${RESET}"
        echo ""
        # Update definitions state variables
        update_definitions_state

    else
        # Copy failed, display relevant errors
        echo -e "${RED}Something went wrong, please make sure the selected rclone remote is correctly configured.${RESET}"
        echo -e "${RED}Also note that if you're using object based storage, your backup location should start with a bucket name.${RESET}"
        read -p "$(echo -e "${BLUE}Would you like to open rclone configuration screen? (y/n): ${RESET}")" rclone_reconfig
        if [ $rclone_reconfig == "y" ] || [ $rclone_reconfig == "yes" ]; then
            configure_rclone
            generate_backup_script
            return
        else
            generate_backup_script
            return
        fi
    fi
}

# Function to manage local automated backups
manage_automated_backups() {

    # Exit on errors within this function
    set -e

    # Clear screen and display a title
    clear_screen
    echo -e "${BOLD}${UNDERLINE}Manage backups > Manage automated backups${RESET}"

    # Check if a backup index is already provided.
    # If index is provided, use it later to automatically display the selected backup instead of showing list of available backups
    backup_already_selected=false
    if [ $# -eq 1 ] && [[ $1 =~ ^[0-9]+$ ]]; then
        # Assign the index to the variable
        backup_already_selected=$1
    fi

    # Initialize arrays to store backup details
    declare -a backup_statuses
    declare -a backup_scripts
    declare -a backup_types
    declare -a backup_cron_expressions
    declare -a backup_hashes
    declare -a backup_names
    declare -a backup_schedules
    declare -a backup_domains
    declare -a backup_paths
    declare -a remote_locations
    declare -a rclone_remotes
    declare -a retention_periods

    # Loop through existing backup scripts under $CRON_SCRIPTS_DIR
    for script_file in "$CRON_SCRIPTS_DIR"/*; do
        if [ -f "$script_file" ]; then

            local script_filename=$(echo "$(basename "$script_file")")
            # Check if there is line with our script name in the cron file
            local backup_schedule_line=$(grep -E ".*$script_filename" "$CRON_FILE" | grep -oP '(\S+ ){4}\S+')

            # Check if a valid line was found
            local backup_status="Inactive"
            if [ -n "$backup_schedule_line" ]; then
                backup_status="Active"
            fi

            # Extract other details from the backup script variables
            local backup_type=$(grep -oP '(?<!\w)type="\K[^"]+' "$script_file")                                  # only double quote enclosed values
            local creation_date=$(grep -oP 'creation_date="\K[^"]+' "$script_file")                              # only double quote enclosed values
            local cron_expression=$(grep -oP 'cron_expression="\K[^"]+' "$script_file")                          # only double quote enclosed values
            local backup_hash=$(grep -oP '(?<!\w)hash="\K[^"]+' "$script_file")                                  # only double quote enclosed values
            local backup_domain=$(grep -oP 'domain="\K[^"]+' "$script_file")                                     # only double quote enclosed values
            local backup_path=$(grep -oP 'domain_path="\K[^"]+' "$script_file")                                  # only double quote enclosed values
            local remote_location=$(grep -oP 'remote_backup_location="\K[^"]+' "$script_file")                   # only double quote enclosed values
            local rclone_remote=$(grep -oP 'rclone_remote="\K[^"]+' "$script_file")                              # only double quote enclosed values
            local retention_period=$(grep -oP 'retention_period=("[^"]*"|\S+)' "$script_file" | cut -d '=' -f 2) # Extract value that doesn't have double quotes

            # Validate the integrity of this script
            local existing_script_prefix="${script_filename%%_*}"
            local generated_script_prefix=$(echo -n "$creation_date-$backup_domain-$cron_expression-$retention_period-$remote_location-$rclone_remote-$backup_type" | md5sum | awk '{print $1}') # used to prefix the backup script

            if [ "$existing_script_prefix" != "$generated_script_prefix" ]; then
                continue # There is no match, move to next iteration
            fi

            # Extract backup_time from the cron_expression
            hour=$(echo "$cron_expression" | awk '{print $2}')
            minute=$(echo "$cron_expression" | awk '{print $1}')
            backup_time=$(printf "%02d:%02d" "$hour" "$minute")

            # Extract backup frequency from cron_expression
            IFS=" " read -r -a cron_expression_parts <<<"$cron_expression"
            # Determine the frequency
            day="${cron_expression_parts[2]}"
            month="${cron_expression_parts[3]}"
            day_of_the_week="${cron_expression_parts[4]}"
            if [[ "$day" = "*" && "$month" = "*" && "$day_of_the_week" = "*" ]]; then
                backup_frequency="daily"
            elif [[ "$day" = "*" && "$month" = "*" ]]; then
                backup_frequency="weekly"
            else
                backup_frequency="monthly"
            fi

            # Store the extracted details in arrays
            backup_statuses+=("$backup_status")
            backup_scripts+=("$script_file")
            backup_types+=("$backup_type")
            backup_cron_expressions+=("$cron_expression")
            backup_hashes+=("$backup_hash")
            backup_names+=("${backup_domain} ${backup_frequency} backup at ${backup_time} to ${rclone_remote}")
            backup_schedules+=("$backup_frequency")
            backup_domains+=("$backup_domain")
            backup_paths+=("$backup_path")
            remote_locations+=("$remote_location")
            rclone_remotes+=("$rclone_remote")
            retention_periods+=("$retention_period")

        fi
    done

    # Check if any backups were found
    if [ "${#backup_names[@]}" -eq 0 ]; then
        echo -e "${YELLOW}The existing backup scripts are either deleted or corrupt, check /cron_scripts folder to confirm.${RESET}"
        return
    fi

    if [ $backup_already_selected == false ]; then
        # Display the list of available backups for selection
        echo -e "${BOLD}${UNDERLINE}Available Backups: ${RESET}"
        for i in "${!backup_names[@]}"; do
            # Prepare a bullet point with a different color depending on backup status
            if [[ "${backup_statuses[i]}" == "Active" ]]; then
                bullet="${GREEN}●${RESET}"
            else
                bullet="${YELLOW}●${RESET}"
            fi
            index=$((i + 1)) # Increment the index by 1
            echo -e "$bullet $index. ${backup_names[i]} [${backup_types[i]}]"
        done

        # Ask the user to select a backup for detailed management
        read -p "$(echo -e "${BOLD}${BLUE}Select a backup to manage (or 'q' to go back): ${RESET}")" choice

        if [ "$choice" == "q" ]; then
            clear_screen "force"
            return
        fi

        # Validate the user's choice
        if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -le 0 ] || [ "$choice" -gt "${#backup_names[@]}" ]; then
            echo -e "${RED}Invalid choice. Please enter a valid number.${RESET}"
            return
        fi
    fi

    # Display details and management options for the selected backup

    local selected_backup_index
    if [ $backup_already_selected != false ]; then
        selected_backup_index=$backup_already_selected
    else
        selected_backup_index=$((choice - 1))
    fi

    local selected_backup_status="${backup_statuses[selected_backup_index]}"
    local selected_backup_script="${backup_scripts[selected_backup_index]}"
    local selected_backup_type="${backup_types[selected_backup_index]}"
    local selected_backup_cron_expression="${backup_cron_expressions[selected_backup_index]}"
    local selected_backup_hash="${backup_hashes[selected_backup_index]}"
    local selected_backup_name="${backup_names[selected_backup_index]}"
    local selected_backup_schedule="${backup_schedules[selected_backup_index]}"
    local selected_backup_domain="${backup_domains[selected_backup_index]}"
    local selected_backup_path="${backup_paths[selected_backup_index]}"
    local selected_backup_remote_location="${remote_locations[selected_backup_index]}"
    local selected_backup_rclone_remote="${rclone_remotes[selected_backup_index]}"
    local selected_backup_retention_period="${retention_periods[selected_backup_index]}"

    save_cursor_position "alt" # Save cursor position ( used for enable/disable/return to clear everything up to this point )
    # Only clear screen if the a backup is not already selected
    if [ $backup_already_selected == false ]; then
        clear_screen "force"
    fi

    echo -e "${BOLD}${UNDERLINE}Available Backups > Backup Details:${RESET}"
    if [ "$selected_backup_status" == "Active" ]; then
        echo -e "${BOLD}Backup Status:${RESET} ${GREEN}$selected_backup_status${RESET}"
    else
        echo -e "${BOLD}Backup Status:${RESET} ${YELLOW}$selected_backup_status${RESET}"
    fi
    echo -e "${BOLD}Backup Type:${RESET} ${BLUE}$selected_backup_type${RESET}"
    echo -e "${BOLD}Backup ID:${RESET} $selected_backup_hash"
    echo -e "${BOLD}Backup Name:${RESET} ${RESET} $selected_backup_name"
    echo -e "${BOLD}Backup Schedule:${RESET} $selected_backup_schedule"
    echo -e "${BOLD}Backup Domain:${RESET} $selected_backup_domain"
    echo -e "${BOLD}Backup Path:${RESET} $selected_backup_path"
    echo -e "${BOLD}Remote Location:${RESET} $selected_backup_remote_location"
    echo -e "${BOLD}Rclone Remote:${RESET} $selected_backup_rclone_remote"
    echo -e "${BOLD}Retention Period:${RESET} $selected_backup_retention_period days"
    echo ""

    save_cursor_position

    # Save the original PS3 value
    local original_ps3="$PS3"
    while true; do
        # Ask the user for further actions (e.g., delete, enable, disable)
        options=("Enable" "Delete" "View/restore remote backups" "Return to the previous menu")
        if [ "$selected_backup_status" == "Active" ]; then
            options=("Disable" "Delete" "View/restore remote backups" "Return to the previous menu")
        fi

        PS3="$(echo -e "${BOLD}${BLUE}Type the desired option number to continue: ${RESET}")"
        select choice in "${options[@]}"; do
            case "$choice" in
            "Disable")
                # Construct the cron pattern and remove the associated cron line from the specified cron file
                cron_pattern="^${selected_backup_cron_expression//\*/\\*} .*$(basename "$selected_backup_script")"
                sudo sed -i "/$cron_pattern/d" "$CRON_FILE"

                restore_cursor_position "alt"
                clear_screen "force"
                echo -e "${BOLD}${GREEN}'$selected_backup_name'${RESET} ${GREEN}has been disabled successfully.${RESET}"
                manage_automated_backups "$selected_backup_index" # Reload this function with the current backup pre-selected
                return
                ;;
            "Enable")
                echo "$selected_backup_cron_expression root /bin/bash $PWD/$selected_backup_script" >>"$CRON_FILE"

                restore_cursor_position "alt"
                clear_screen "force"
                echo -e "${BOLD}${GREEN}'$selected_backup_name'${RESET} ${GREEN}has been enabled successfully.${RESET}"
                manage_automated_backups "$selected_backup_index" # Reload this function with the current backup pre-selected
                return
                ;;
            "Delete")
                echo ""
                echo -e "${RED_BG}---------------------------------------------------------------------------${RESET}"
                echo -e "${RED_BG}--------------------------- PROCEED WITH CAUTION --------------------------${RESET}"
                echo -e "${RED_BG}---------------------------------------------------------------------------${RESET}"
                echo -e "${RED_BG}-------------- If you choose to delete this automated backup --------------${RESET}"
                echo -e "${RED_BG}----------- you'll lose access to the backup restoration feature ----------${RESET}"
                echo -e "${RED_BG}---------- and any management features associated with the backup ---------${RESET}"
                echo -e "${RED_BG}---------------------------------------------------------------------------${RESET}"
                echo ""
                echo -e "${BOLD}${YELLOW}NOTE: ${RESET}You backup files on the remote server will not be effected.${RESET}"
                echo ""

                # Confirm with the user before deleting the backup
                read -p "$(echo -e "${BOLD}${RED}Choose an action (c: Confirm deletion, b: Bail out): ${RESET}")" confirm
                if [ "$confirm" == "c" ]; then
                    # Remove the backup script file
                    sudo rm -f "$selected_backup_script"

                    # Construct the cron pattern and remove the associated cron line from the specified cron file
                    cron_pattern="^${selected_backup_cron_expression//\*/\\*} .*$(basename "$selected_backup_script")"
                    sudo sed -i "/$cron_pattern/d" "$CRON_FILE"

                    clear_screen "force"
                    echo -e "${BOLD}${GREEN}'$selected_backup_name'${RESET} ${GREEN}has been deleted successfully.${RESET}"
                    update_definitions_state
                    manage_automated_backups
                    return

                else
                    restore_cursor_position
                    echo -e "${BOLD}${YELLOW}'$selected_backup_name'${RESET} ${YELLOW}deletion has been aborted.${RESET}"
                    echo ""
                fi
                ;;
            "View/restore remote backups")

                if [ $selected_backup_type == "incremental" ]; then

                    echo ""
                    echo -e "${YELLOW}Pulling remote incremental backups ...${RESET}"
                    echo ""

                    # Extract repo password from backup file ( may not have double quotes )
                    local restic_password=$(grep -oP 'restic_password=("[^"]*"|\S+)' "$selected_backup_script" | cut -d '=' -f 2)

                    # List existing snapshots
                    sudo RESTIC_PASSWORD="${restic_password}" restic -r "rclone:${selected_backup_rclone_remote}:${selected_backup_remote_location}" snapshots

                    # Ask the user to select a backup for restoration
                    read -p "$(echo -e "${BOLD}${BLUE}Enter the ID of the backup you'd like to restore ( or q to go back ): ${RESET}")" selected_remote_backup

                    # Go back if the user typed q
                    if [ $selected_remote_backup == "q" ]; then
                        restore_cursor_position
                        break # break out of the select statement to restart the while loop
                    fi

                    # Confirm with the user before restoring the backup
                    echo ""
                    echo -e "You selected: ${BOLD}$selected_remote_backup${RESET}"
                    echo -e "Choose a restore approach:"
                    echo -e "${BOLD}${YELLOW}1. ${RESET}Restore only"
                    echo -e "${BOLD}${YELLOW}2. ${RESET}Clear and restore"

                    read -p "$(echo -e "${BOLD}${BLUE}Enter the number of your choice (1/2)${RESET} ${BLUE}( or q to go back ): ${RESET}")" restore_approach_choice

                    # Go back if the user typed q
                    if [ $restore_approach_choice == "q" ]; then
                        restore_cursor_position
                        break # break out of the select statement to restart the while loop
                    fi

                    # Handle user restore choice
                    if [[ $restore_approach_choice == "1" || $restore_approach_choice == "2" ]]; then
                        restore_cursor_position

                        # Show a pre-restore backup notice
                        echo ""
                        echo -e "${YELLOW}Taking a pre-restore backup ...${RESET}"
                        # Take a backup using backup script with the arg "restore" to indicate this is a pre-restore backup
                        sudo bash $selected_backup_script "restore"

                        # Clear the destination folder if "clear and restore is selected"
                        if [[ $restore_approach_choice == "2" ]]; then
                            sudo rm -rf "${selected_backup_path%/}"/*
                        fi

                        # Show a restoration notice
                        echo ""
                        echo -e "${YELLOW}Restoring${RESET} ${BOLD}${YELLOW}$selected_remote_backup${RESET} ${YELLOW}to:${RESET} ${BOLD}${YELLOW}$selected_backup_path${RESET}"

                        # Restore to the same backed up path
                        # Use --target to manipulate the destination
                        # Use --include to only include specific folder or file from snapshot
                        # use ":path/to/folder" after the snapshot ID to restore the content of a specific folder directly
                        sudo RESTIC_PASSWORD="${restic_password}" restic -r "rclone:${selected_backup_rclone_remote}:${selected_backup_remote_location}" restore $selected_remote_backup --target "/"
                    else
                        restore_cursor_position
                        echo -e "${YELLOW}restore has been aborted.${RESET}"
                        echo ""
                    fi
                else

                    echo ""
                    echo -e "${YELLOW}Pulling remote backups count & total size...${RESET}"

                    # Show backups size and count
                    echo ""
                    sudo rclone size "${selected_backup_rclone_remote}":"${selected_backup_remote_location}" --include "${selected_backup_hash}_*"

                    echo ""
                    echo -e "${YELLOW}Pulling remote backups list...${RESET}"

                    # Capture the list of backup files
                    local backup_list_output=$(sudo rclone ls "${selected_backup_rclone_remote}":"${selected_backup_remote_location}" --include "${selected_backup_hash}_*")

                    # Check if the backup list is empty
                    if [ -z "$backup_list_output" ]; then
                        restore_cursor_position
                        echo -e "${YELLOW}No remote backups found.${RESET}"
                        echo ""
                        break # break out of the select statement to restart the while loop
                    fi

                    # Capture the list of remote backup files
                    local remote_backup_files=()
                    local remote_backup_lines=()
                    while IFS= read -r line; do
                        # Remove leading spaces from the line
                        line="${line#"${line%%[![:space:]]*}"}"

                        # Extract the size and filename from the line
                        local remote_backup_size="${line%% *}" # Extract size (everything before the first space)
                        local remote_backup_name="${line#* }"  # Extract filename (everything after the first space)

                        # Remove the MD5 prefix from remote_backup_name
                        local noprefix_remote_backup_name="${remote_backup_name#*_}"

                        # Extract the date and time from the filename
                        if [[ "$noprefix_remote_backup_name" =~ ([0-9]{2}-[0-9]{2}-[0-9]{4})_([0-9]{2}-[0-9]{2}).*\.tar\.gz ]]; then
                            backup_file_date="${BASH_REMATCH[1]}"
                            backup_file_time="${BASH_REMATCH[2]//-/:}"

                            # Format the time to display in 12-hour format with AM/PM
                            backup_file_time=$(date -d "$backup_file_time" +"%I:%M%p")

                            # Format the size in a human-readable format (MB, GB, etc.)
                            backup_size_readable=$(numfmt --to=iec --suffix=B --format="%.2f" "$remote_backup_size")

                            # Increment the index for numbering the options
                            if [ $index == 1 ]; then
                                backup_file_date="$backup_file_date-15455"
                            fi
                            # Add the formatted line to the remote_backup_files array
                            remote_backup_files+=("$remote_backup_name")
                            remote_backup_lines+=("$backup_file_date $backup_file_time $backup_size_readable $noprefix_remote_backup_name")
                        fi
                    done <<<"$backup_list_output"

                    # Display the backup list as a table with aligned headers
                    echo ""
                    echo -e "${BOLD}${YELLOW}#   Date        Time     Size     Name${RESET}"
                    # Calculate the maximum length of the index numbers to align them properly
                    local max_index_length="${#remote_backup_lines[@]}"
                    while ((max_index_length > 0)); do
                        max_index_length=$((max_index_length / 10))
                        local index_length=$((index_length + 1))
                    done

                    for ((i = 0; i < ${#remote_backup_lines[@]}; i++)); do
                        # Calculate the padding for the index numbers
                        local padding_length=$((index_length - ${#i}))
                        local padding=""
                        for ((j = 0; j < padding_length; j++)); do
                            padding+=" "
                        done
                        local item_index=$((i + 1))
                        echo -e "${BOLD}${YELLOW}${padding}${item_index}. ${RESET}${remote_backup_lines[i]}"
                    done | column -t

                    # Ask the user to select a backup for restoration
                    read -p "$(echo -e "${BOLD}${BLUE}Enter the number of the backup to restore (1-${#remote_backup_lines[@]}) ${BLUE}( or q to go back ): ${RESET}")" restore_choice

                    # Validate the user's choice
                    if [[ ! "$restore_choice" =~ ^[0-9]+$ ]] || [ "$restore_choice" -lt 1 ] || [ "$restore_choice" -gt "${#remote_backup_lines[@]}" ]; then
                        restore_cursor_position
                        echo -e "${RED}Invalid choice. Please enter a valid number.${RESET}"
                        break # break out of the select statement to restart the while loop
                    fi

                    # Go back if the user typed q
                    if [ $restore_choice == "q" ]; then
                        restore_cursor_position
                        break # break out of the select statement to restart the while loop
                    fi

                    # Get the selected backup based on the user's choice
                    local selected_remote_backup="${remote_backup_files[restore_choice - 1]}"

                    # Confirm with the user before restoring the backup
                    echo ""
                    echo -e "You selected: ${BOLD}$selected_remote_backup${RESET}"
                    echo -e "Choose a restore approach:"
                    echo -e "${BOLD}${YELLOW}1. ${RESET}Restore only"
                    echo -e "${BOLD}${YELLOW}2. ${RESET}Clear and restore"

                    read -p "$(echo -e "${BOLD}${BLUE}Enter the number of your choice (1/2)${RESET} ${BLUE}( or q to go back ): ${RESET}")" restore_approach_choice
                    # Go back if the user typed q
                    if [ $restore_approach_choice == "q" ]; then
                        restore_cursor_position
                        break # break out of the select statement to restart the while loop
                    fi

                    # Handle user restore choice
                    if [[ $restore_approach_choice == "1" || $restore_approach_choice == "2" ]]; then
                        restore_cursor_position

                        # Show a pre-restore backup notice
                        echo ""
                        echo -e "${YELLOW}Taking a pre-restore backup ...${RESET}"
                        # Take a backup using backup script with the arg "restore" to indicate this is a pre-restore backup
                        sudo bash $selected_backup_script "restore"

                        # Show a restoration notice
                        echo ""
                        echo -e "${YELLOW}Restoring ${RESET}${BOLD}${YELLOW}$selected_remote_backup${RESET} ${YELLOW}to${RESET} ${BOLD}${YELLOW}$selected_backup_path${RESET}"
                        # Pull the backup from remote
                        sudo rclone copyto --progress "${selected_backup_rclone_remote}":"${selected_backup_remote_location}${selected_remote_backup}" "${TMP_DIR}/${selected_remote_backup}.tmp"

                        # Handle "Clear and restore" option
                        if [ $restore_approach_choice == "2" ]; then
                            sudo rm -rf "${selected_backup_path%/}"/*
                        fi

                        # Unzip the backup file inside the destination folder
                        sudo tar -xzf "${TMP_DIR}/${selected_remote_backup}.tmp" -C "$selected_backup_path"
                        sudo rm "${TMP_DIR}/${selected_remote_backup}.tmp"

                    else
                        restore_cursor_position
                        echo -e "${BOLD}${YELLOW}'$selected_remote_backup'${RESET} ${YELLOW}restoration has been aborted.${RESET}"
                        echo ""
                    fi
                fi

                # Show a db import notice
                echo ""
                echo -e "${YELLOW}Importing the database ...${RESET}"
                # Now import the database using wp cli and delete it afterwards
                local wp_owner=$(sudo stat -c "%U" ${selected_backup_path})                                                # get WordPress folder owner
                local sql_file=$(find "$selected_backup_path" -type f -name "*${selected_backup_hash}_*.sql" -print -quit) # find the sql file path
                sudo -u "${wp_owner}" -i -- wp db import "${sql_file}" --path="${selected_backup_path}"                    # import db
                sudo rm "${sql_file}"                                                                                      # Delete the SQL file after it's been imported

                clear_screen "force"
                # Show a success message
                echo -e "${BOLD}${GREEN}Restore successfully completed.${RESET}"
                echo ""
                manage_automated_backups
                return
                ;;
            "Return to the previous menu")
                restore_cursor_position "alt"
                clear_screen "force"
                manage_automated_backups
                return
                ;;
            *)
                restore_cursor_position
                echo -e "${RED}Invalid action. Please choose a valid action.${RESET}"
                ;;
            esac
            break
        done
    done

    # Restore the original PS3 value
    PS3="$original_ps3"
}

# Function to manage automated backups
manage_backups() {
    while true; do

        # Go back to the main menu in case all backups has been deleted
        if [ $HAS_AUTOMATED_BACKUPS == false ]; then
            clear_screen
            return
        fi

        # Shpw the backup management menu
        clear_screen "ignore" "generate_backup_script" "manage_automated_backups"
        echo -e "${BOLD}${UNDERLINE}Manage backups${RESET}"
        echo "1. Manage automated backups"
        echo "2. Create a new automated backup"
        echo "3. Return to the previous menu"
        read -p "$(echo -e "${BOLD}${BLUE}Enter your choice: ${RESET}")" choice

        case "$choice" in
        1)
            manage_automated_backups
            ;;
        2)
            generate_backup_script
            ;;
        3)
            clear_screen "force"
            return
            ;;
        *)
            clear_screen "force"
            echo -e "${RED}Invalid choice. Please select a valid option.${RESET}"
            ;;
        esac
    done
}

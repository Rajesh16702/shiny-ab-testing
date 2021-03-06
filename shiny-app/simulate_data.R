library(tidyverse)
library(lubridate)
library(scales)

source('r_scripts/helpers_check_data_integrity.R', chdir=TRUE)
source('r_scripts/helpers_processing.R', chdir=TRUE)
source('../unit_tests/unit_test_helpers.R')

baseline_conversion_rates <- c(0.10, 0.07, 0.05, 0.03)

##########################################################################################################
# SIMULATE EXPERIMENT INFO
##########################################################################################################

# NOTE: is_control can be a setting within the shiny app; but we'll set it here becuase that 
# functionality is more suited towards a v2 than a v1
# We could also include a description, etc., in this dataset.
experiment_info <- as.data.frame(tribble(
    ~experiment_id,                             ~variation,      ~is_control,
    #------------------------------------------|--------------------|----
    "Redesign Website",                         "Original",          TRUE,
    "Redesign Website",                         "Site Redesign",     FALSE,
    "New Signup CTA Color",                     "Green Signup CTA",  TRUE,
    "New Signup CTA Color",                     "Blue Signup CTA",   FALSE,
    "Show Discount for First-Time Visitors",    "No Offer",          TRUE,
    "Show Discount for First-Time Visitors",    "Sales Offer",       FALSE,
    "Ask Additional Questions During Signup",   "Old Signup Path",   TRUE,
    "Ask Additional Questions During Signup",   "New Signup Path",   FALSE
))
check_data__experiment_info(experiment_info)
write.csv(experiment_info, file='simulated_data/experiment_info.csv', row.names = FALSE)

##########################################################################################################
# SIMULATE ATTRIBUTION WINDOWS
##########################################################################################################

# names of the metrics/conversions to track
metrics_names <- c('Sign Up', 'Use Feature 1', 'Talk to Sales', 'Pay/Subscribe')

# allowed number of days between seeing the experiment and giving credit for a conversion
# e.g. signup should happen quick, but we may want to give people more time to subscribe/pay for the service,
# since people want to try out the features before they decide to pay (e.g. if the service offers a trial or freemium)
attribution_windows_days <- c(2, 3, 5, 7)
attribution_windows <- data.frame(metric_id = metrics_names,
                                  attribution_window = attribution_windows_days,
                                  stringsAsFactors = FALSE)
attribution_windows <- expand.grid(experiment_id=unique(experiment_info$experiment_id),
                                   metric_id = metrics_names,
                                   stringsAsFactors = FALSE) %>%
    inner_join(attribution_windows, by = 'metric_id') %>%
    arrange(experiment_id, attribution_window) %>%
    mutate_if(is.factor, as.character)

check_data__attribution_windows(attribution_windows, experiment_info)
write.csv(attribution_windows, file='simulated_data/attribution_windows.csv', row.names = FALSE)

##########################################################################################################
# SIMULATE WEBSITE TRAFFIC
##########################################################################################################

# unique daily visits e.g. 1 record means that the user_id may have visited the site 1+ times for that day
# (the number of times does not matter)

total_website_traffic <- 2000000
set.seed(42)
ids <- floor(runif(total_website_traffic, min=1, max=total_website_traffic * 0.8))

# simulate dates over last e.g 6 months
# we need to duplicate ids/days to simulate people visiting multiple paths per day; we'll use this information for our priors
number_of_months <- 6

website_traffic <- data.frame(user_id=ids)
simulate_num_days <- number_of_months*30

# offset from todays day (i.e. today - first_time_visit_index == first-time-visit)
set.seed(42)
# need to scale the output of the log(exponential) distribution to the number of days we are simulateing
first_time_visit_offset <- round(scale_a_b(log2(rexp(length(unique(website_traffic$user_id)), rate=0.9) +1),
                                           a=0, 
                                           b=simulate_num_days))
#hist(first_time_visit_offset)
# create dataframe with the user-id and the offset that we will use from the current date
# we'll use the current date so we can simulate the latest experiment is currently running 
first_time_users <- data.frame(user_id=unique(ids), visit_offset=first_time_visit_offset)

first_time_users <- first_time_users %>%
    mutate(first_visit_date=today() - visit_offset) %>%
    select(-visit_offset) %>%
    # we need to filter because the beginning of the simulated data has too few traffic and the there is a dip in the end
    filter(first_visit_date > Sys.Date() - round(simulate_num_days * 0.55),
           first_visit_date <= Sys.Date() - 7)

website_traffic <- inner_join(website_traffic, first_time_users, by = 'user_id')
# right now, we have a dataset with user-ids, that repeat for the number of unique days they have
# visited the site, but the date field is the same for the days for given user-id
# what we need to do now is simulate the user-id visiting the site on different days.
website_traffic <- website_traffic %>%
    group_by(user_id) %>%
    mutate(visit_index = row_number()) %>%
    ungroup()

# generate a new date based on the gamma distribution; note setting the seed based on the user-id,
# which i wanted to do to recreate the same data, causes the distribution to become strange
generated_website_traffic <- pmap(list(website_traffic$visit_index,
                          website_traffic$first_visit_date,
                          website_traffic$user_id),
                     function(x, y, z) generate_new_date(x, y, z))

# pmap is losing the "date" and is returning a number, so we have to convert back; not sure this is the best way
generated_website_traffic <- unlist(generated_website_traffic)
website_traffic$visit_date <- as.Date(generated_website_traffic, origin = Sys.Date() - as.numeric(Sys.Date()))

# NOTE: some of the dates generated will be the same. BUT, that could represent multiple different pages 
# i.e. paths in the same day, so let's add path before we remove duplicates
website_traffic <- website_traffic %>%
    select(user_id, visit_date) %>%
    arrange(user_id, visit_date)

# duplicate various pages to simulate more page visits
paths <- c(rep('example.com', 4),
           rep('example.com/features', 3), 
           rep('example.com/pricing', 2), 
           'example.com/demo')
#set.seed(42)
path_index <- ceiling(runif(nrow(website_traffic), min=0, max=length(paths)))
website_traffic$path <- map_chr(path_index, ~ paths[.])

# some of the dates generated will be the same. BUT, that could represent multiple different pages in the same day
# so let's add path before we remove duplicates
website_traffic <- distinct(website_traffic)

website_traffic <- as.data.frame(website_traffic) %>%
# we need to (RE)filter because the beginning of the simulated data has too few traffic and the there is a dip in the end
filter(visit_date > Sys.Date() - round(simulate_num_days * 0.55),
       visit_date <= Sys.Date() - 7)

seconds_in_day <- 86400
# need to simulate time-stamps and convert visit_date from date to date/time
set.seed(42)
simulated_seconds <-round(runif(nrow(website_traffic), min = 0, max=seconds_in_day - 1))
website_traffic$visit_date <- as.POSIXct(website_traffic$visit_date + seconds(simulated_seconds))

########
# plot various characteristics of our simulated website traffic
########
plot_object <- first_time_users %>%
    count(first_visit_date) %>%
    ggplot(aes(x=first_visit_date, y=n)) +
    geom_line() +
    expand_limits(y=0) +
    labs(title='Simulated Daily website_traffic') +
    scale_x_date(date_labels="%y-%m-%d",date_breaks  ="5 days") +
    theme(axis.text.x = element_text(angle = 30, hjust = 1))
plot_object %>% test_save_plot(file='simulated_data_plots/simulated_daily_website_traffic.png')

plot_object <- website_traffic %>%
    count(user_id) %>%  # gives a count of days visited for each user-id
    count(n) %>%  # gives a count user-ids for each number of unique website_traffic i.e. will give a distribution of unique (by day/path) website_traffic
    mutate(n=factor(n),
           percent_of_user_ids = nn / length(unique(website_traffic$user_id))) %>%
    rename(unique_days_visited=n,
           number_of_ids=nn) %>%
    ggplot(aes(x=unique_days_visited, y=percent_of_user_ids)) +
    geom_col() +
    geom_text(aes(label=percent(percent_of_user_ids)), vjust=-0.3) +
    geom_text(aes(label=number_of_ids), vjust=-1) +
    labs(title='Distribution of Unique Website Traffic Per User-Id')
plot_object %>% test_save_plot(file='simulated_data_plots/unique_website_traffic_per_user_id.png')

plot_object <- website_traffic %>%
    count(path) %>%
    mutate(path=fct_reorder(path, desc(n))) %>%
    ggplot(aes(x=path, y=n)) +
    geom_col() +
    labs(title='Total website_traffic (day/user) single row represents >=1 Website Traffic for that day/user/path')
plot_object %>% test_save_plot(file='simulated_data_plots/count_of_traffic_to_paths.png')

plot_object <- website_traffic %>%
    group_by(user_id) %>%
    filter(n() > 1) %>%
    summarise(t=floor(sd(as.numeric(visit_date) / 24 / 60 / 60))) %>%
    ggplot(aes(x=t)) +
        geom_histogram() +
        labs(title='Distribution of Number of Days between Website Traffic')
plot_object %>% test_save_plot(file='simulated_data_plots/distribution_of_num_days_between_traffic.png')

temp <- inner_join(
    website_traffic %>% 
        group_by(user_id) %>%
        summarise(first_visit_date=min(visit_date)) %>%
        mutate(first_visit_date = floor_date(first_visit_date, unit = 'days')) %>%
        count(first_visit_date) %>%
        rename(date=first_visit_date,
               new_visits=n),
    website_traffic %>%
        mutate(visit_date = floor_date(visit_date, unit = 'days')) %>%
        group_by(visit_date) %>%
        summarise(all_visits=n()) %>%
        rename(date=visit_date),
    by='date')

plot_object <- temp %>% 
    gather(user_type, num_users, -date) %>%
    ggplot(aes(x=date, y=num_users, color=user_type)) +
        geom_line() +
        labs(title='New vs. All Visits Over time')
plot_object %>% test_save_plot(file='simulated_data_plots/new_vs_all_visits_over_time.png')

plot_object <- temp %>%
    mutate(percent_new_visits = new_visits / all_visits) %>%
    ggplot(aes(x=date, y=percent_new_visits)) +
        geom_line() +
        expand_limits(y=0) +
        labs(title="Percent New users Over time")
plot_object %>% test_save_plot(file='simulated_data_plots/percent_new_visits_over_time.png')

plot_object <- website_traffic %>%
    mutate(visit_date = floor_date(visit_date, unit = 'days')) %>%
    count(visit_date, path) %>%
    ggplot(aes(x=visit_date, y=n, color=path)) +
    geom_line() +
    labs(title='Website Traffic (per day/user) i.e. single row represents >=1 Website Traffic for that day/user/path')
plot_object %>% test_save_plot(file='simulated_data_plots/website_traffic_per_path.png')

check_data__website_traffic(website_traffic)
write.csv(website_traffic, file='simulated_data/website_traffic.csv', row.names = FALSE)

##########################################################################################################
# SIMULATE EXPERIMENTS
# for each experiment, we want to simulate, from the current visits/traffic dataset, who saw the experiment,
# on which page, and which variation
##########################################################################################################
create_experiment_visits <- function(website_traffic, start_date, end_date, experiment_paths, 
                                     current_experiment_id, variation_names,
                                     # baseline CRs are used to graph the percent of total sample size that
                                     # has been acheived over time, say at a 5% increase
                                     baseline_conversion_rates=c(0.03, 0.05, 0.07, 0.10)) {


    # this will get the first visit record (so i can retain the correct path) for the user between the
    # start/end dates for the relevant paths, it does not ensure the user is new to the site
    experiment_visits <- website_traffic %>%
        # get all records between the valid dates and for the paths the experiment is on
        filter(visit_date >= start_date & visit_date <= end_date,
               path %in% experiment_paths) %>%
        group_by(user_id) %>%
        # get the first visit for that user (again, for the valid dates/paths)
        mutate(visit_index=rank(visit_date, ties.method = "first")) %>%
        ungroup() %>%
        filter(visit_index == 1) %>%
        select(-visit_index) %>%
        rename(first_joined_experiment=visit_date) %>%
        mutate(experiment_id=current_experiment_id)
        
    experiment_visits$variation <- map_chr(experiment_visits$user_id, ~ get_random_variation(variation_names, .))
    
    # make sure no duplicated user_ids
    stopifnot(nrow(experiment_visits) == length(unique(experiment_visits$user_id)))
    
    plot_object <- experiment_visits %>%
        count(variation) %>%
        ggplot(aes(x=variation, y=n, fill=variation)) +
        geom_col() +
        theme(legend.position = 'none') +
        labs(title=paste('Variation Count -', current_experiment_id))
    plot_object %>% test_save_plot(file=paste0('simulated_data_plots/create_', 
                                               current_experiment_id,
                                               '_variation_count.png'))
        
    
    sample_sizes_required <- map_dbl(baseline_conversion_rates,
                                     ~ calculate_total_sample_size(.,
                                                                   percent_increase=0.05,
                                                                   power=0.8,
                                                                   alpha=0.05))
    names(sample_sizes_required) <- paste0('baseline_', baseline_conversion_rates)
        
    experiment_count <- experiment_visits %>%
        mutate(first_joined_experiment = floor_date(first_joined_experiment, unit = 'days')) %>%
        count(first_joined_experiment) %>%
        rename(daily_traffic=n) %>%
        arrange(first_joined_experiment) %>%
        mutate(cumulative_traffic=cumsum(daily_traffic))
    
    # this calculates the percent of the cumulative traffic relative to the total sample size needed for the
    # corresponding baseline CR
    for(baseline_index in 1:length(sample_sizes_required)) {
        
        experiment_count[, names(sample_sizes_required)[baseline_index]] <- experiment_count$cumulative_traffic / sample_sizes_required[baseline_index]
    }

    plot_object <- experiment_count %>%
        ggplot(aes(x=first_joined_experiment, y=daily_traffic)) +
        geom_line() +
        geom_point() +
        geom_text(aes(label=daily_traffic), check_overlap = TRUE, vjust=-0.5) +
        expand_limits(y=0)+
        labs(title='Number of People Entering Experiment')
    plot_object %>% test_save_plot(file=paste0('simulated_data_plots/create_', 
                                               current_experiment_id,
                                               '_experiment_trials_over_time.png'))
    
    plot_object <- experiment_visits %>%
        mutate(first_joined_experiment = floor_date(first_joined_experiment, unit = 'days')) %>%
        count(first_joined_experiment, variation) %>%
        ggplot(aes(x=first_joined_experiment, y=n, color=variation)) +
        geom_line() +
        geom_point() +
        geom_text(aes(label=n), check_overlap = TRUE, vjust=-0.5) +
        expand_limits(y=0)+
        labs(title='Number of People Entering Experiment - By Variation')
    plot_object %>% test_save_plot(file=paste0('simulated_data_plots/create_', 
                                               current_experiment_id,
                                               '_experiment_trials_over_time_variation.png'))

    plot_object <- experiment_count %>%
        mutate(experiment_day=row_number()) %>%
        select(experiment_day, contains('baseline_')) %>%
        gather(baseline, value, -experiment_day) %>% 
        ggplot(aes(x=experiment_day, y=value, color=baseline)) +
        geom_line() +
        geom_point() +
        geom_text(aes(label=percent(value)), check_overlap = TRUE, vjust=-0.5) +
        expand_limits(y=0)+
        scale_x_continuous(breaks=seq(1, 100)) +
        labs(title='Percent of Cumulative Traffic Attained for the Corresponding Sample Size')
    plot_object %>% test_save_plot(file=paste0('simulated_data_plots/create_', 
                                               current_experiment_id,
                                               '_percent_cumulative_traffic_to_sample_size_over_time.png'))
    
    return (experiment_visits)
}

experiment_names <- unique(experiment_info$experiment_id)
min_traffic_date <- floor_date(min(website_traffic$visit_date), unit='days')
#  max(website_traffic$visit_date) - min_traffic_date

##########################################################################################################
# Experiment 1
##########################################################################################################
# let's start the experiment 1 month after our visits dataset, and run it for a month
min_traffic_date_offset <- 30
experiment_duration <- 30
start_date <- min_traffic_date + days(min_traffic_date_offset) + days(1)
end_date <- start_date + days(experiment_duration)
# all paths
experiment_paths <- unique(paths)
# experiment 1
current_experiment_id <- experiment_names[1]
variation_names <- (experiment_info %>% filter(experiment_id == current_experiment_id))$variation

experiment_traffic_1 <- create_experiment_visits(website_traffic, start_date, end_date, experiment_paths,
                                                 current_experiment_id, variation_names,
                                                 baseline_conversion_rates=baseline_conversion_rates)

##########################################################################################################
# Experiment 2
##########################################################################################################
min_traffic_date_offset <- 40
experiment_duration <- 30
start_date <- min_traffic_date + days(min_traffic_date_offset)
end_date <- start_date + days(experiment_duration)
experiment_paths <- c(#'example.com',
                      'example.com/features', 
                      #'example.com/pricing', 
                      'example.com/demo')
current_experiment_id <- experiment_names[2]
variation_names <- (experiment_info %>% filter(experiment_id == current_experiment_id))$variation

experiment_traffic_2 <- create_experiment_visits(website_traffic, start_date, end_date, experiment_paths,
                                                 current_experiment_id, variation_names,
                                                 baseline_conversion_rates=baseline_conversion_rates)

##########################################################################################################
# Experiment 3
##########################################################################################################
min_traffic_date_offset <- 60
experiment_duration <- 25
start_date <- min_traffic_date + days(min_traffic_date_offset)
end_date <- start_date + days(experiment_duration)
experiment_paths <- c(#'example.com',
                      #'example.com/features',
                      'example.com/pricing',
                      'example.com/demo')
current_experiment_id <- experiment_names[3]
variation_names <- (experiment_info %>% filter(experiment_id == current_experiment_id))$variation

experiment_traffic_3 <- create_experiment_visits(website_traffic, start_date, end_date, experiment_paths,
                                                 current_experiment_id, variation_names,
                                                 baseline_conversion_rates=baseline_conversion_rates)

##########################################################################################################
# Experiment 4
##########################################################################################################
min_traffic_date_offset <- 75
experiment_duration <- 30
start_date <- min_traffic_date + days(min_traffic_date_offset)
end_date <- start_date + days(experiment_duration)
experiment_paths <- c('example.com',
                      'example.com/features', 
                      'example.com/pricing', 
                      'example.com/demo')
current_experiment_id <- experiment_names[4]
variation_names <- (experiment_info %>% filter(experiment_id == current_experiment_id))$variation

experiment_traffic_4 <- create_experiment_visits(website_traffic, start_date, end_date, experiment_paths,
                                                 current_experiment_id, variation_names,
                                                 baseline_conversion_rates=baseline_conversion_rates)

experiment_traffic <- rbind(experiment_traffic_1,
                            experiment_traffic_2,
                            experiment_traffic_3,
                            experiment_traffic_4)

stopifnot(max(experiment_traffic$first_joined_experiment) <= max(website_traffic$visit_date))

plot_object <- experiment_traffic %>%
    mutate(first_joined_experiment = first_joined_experiment) %>%
    count(first_joined_experiment, experiment_id) %>%
    mutate(experiment_id = factor(experiment_id, levels=experiment_names)) %>%
    ggplot(aes(x=first_joined_experiment, y=experiment_id, color=experiment_id)) +
        geom_line(size=5) +
        scale_x_datetime(date_labels="%y-%m-%d",date_breaks  ="10 days") +
        theme(axis.text.x = element_text(angle = 30, hjust = 1, size=6),
              legend.position="none")
plot_object %>% test_save_plot(file='simulated_data_plots/experiment_start_stop.png')

check_data__experiment_traffic(experiment_traffic, experiment_info)
write.csv(experiment_traffic, file='simulated_data/experiment_traffic.csv', row.names = FALSE)

##########################################################################################################
# Create Conversion Rates
# We'll have historical baseline conversion rates for each metric, but we'll want to adjust them up
# or down for each experiment to simulate the experiments (i.e. the variation) having a positive or
# negative (or no) effect.
##########################################################################################################
# create a dataframe that has baseline (i.e. historical) conversion rates fo each metric (will be the same)
# across experiments/variations
# NOTE: i do not change the baseline for future experiments (i.e. each experiment will always start with
# the baseline, which doesn't simulate changes over time, but this is good enough)
adjusted_conversion_rates <- inner_join(inner_join(experiment_info, attribution_windows, by='experiment_id'),
                                        data.frame(metric_id=metrics_names, 
                                                   baseline_conversion_rate=baseline_conversion_rates,
                                                   stringsAsFactors = FALSE),
                                        by = "metric_id") %>%
    select(-attribution_window)

# now we will want to adjust the conversion rate for the a/b groups, we'll start with the baseline and
# update based on a lookup table (of sorts)
adjusted_conversion_rates$adjusted_conversion_rate <- adjusted_conversion_rates$baseline_conversion_rates

percent_change_adjustments <- c(
           #                            experiment_id   variation      is_control     metric_id
    NA,    #                       Redesign Website         Original        TRUE       Sign Up
    NA,    #                       Redesign Website         Original        TRUE Use Feature 1
    NA,    #                       Redesign Website         Original        TRUE Talk to Sales
    NA,    #                       Redesign Website         Original        TRUE Pay/Subscribe
    0.10,  #                       Redesign Website    Site Redesign       FALSE       Sign Up
    0.07,  #                       Redesign Website    Site Redesign       FALSE Use Feature 1
    0.07,  #                       Redesign Website    Site Redesign       FALSE Talk to Sales
    0.05,  #                       Redesign Website    Site Redesign       FALSE Pay/Subscribe
    NA,    #                   New Signup CTA Color Green Signup CTA        TRUE       Sign Up
    NA,    #                   New Signup CTA Color Green Signup CTA        TRUE Use Feature 1
    NA,    #                   New Signup CTA Color Green Signup CTA        TRUE Talk to Sales
    NA,    #                   New Signup CTA Color Green Signup CTA        TRUE Pay/Subscribe
    -0.08, #                   New Signup CTA Color  Blue Signup CTA       FALSE       Sign Up
    -0.08, #                   New Signup CTA Color  Blue Signup CTA       FALSE Use Feature 1
    0,     #                   New Signup CTA Color  Blue Signup CTA       FALSE Talk to Sales
    0,     #                   New Signup CTA Color  Blue Signup CTA       FALSE Pay/Subscribe
    NA,    #  Show Discount for First-Time Visitors         No Offer        TRUE       Sign Up
    NA,    #  Show Discount for First-Time Visitors         No Offer        TRUE Use Feature 1
    NA,    #  Show Discount for First-Time Visitors         No Offer        TRUE Talk to Sales
    NA,    #  Show Discount for First-Time Visitors         No Offer        TRUE Pay/Subscribe
    0.04,  #  Show Discount for First-Time Visitors      Sales Offer       FALSE       Sign Up
    0.04,  #  Show Discount for First-Time Visitors      Sales Offer       FALSE Use Feature 1
    0.15,  #  Show Discount for First-Time Visitors      Sales Offer       FALSE Talk to Sales
    0.15,  #  Show Discount for First-Time Visitors      Sales Offer       FALSE Pay/Subscribe
    NA,    # Ask Additional Questions During Signup  Old Signup Path        TRUE       Sign Up
    NA,    # Ask Additional Questions During Signup  Old Signup Path        TRUE Use Feature 1
    NA,    # Ask Additional Questions During Signup  Old Signup Path        TRUE Talk to Sales
    NA,    # Ask Additional Questions During Signup  Old Signup Path        TRUE Pay/Subscribe
    -0.10, # Ask Additional Questions During Signup  New Signup Path       FALSE       Sign Up
    0.10,  # Ask Additional Questions During Signup  New Signup Path       FALSE Use Feature 1
    NA,    # Ask Additional Questions During Signup  New Signup Path       FALSE Talk to Sales
    NA)    # Ask Additional Questions During Signup  New Signup Path       FALSE Pay/Subscribe

percent_change_adjustments[is.na(percent_change_adjustments)] <- 0
adjusted_conversion_rates <- adjusted_conversion_rates %>%
    mutate(adjusted_conversion_rate=(percent_change_adjustments * baseline_conversion_rates) + baseline_conversion_rates)

# now we want to determine the conversion rates for each person, based on experiment, metric_id, variation, 
# so we can binom distribution based on the conversion rate
# if the person isn't part of an experiment, then we will use the historical conversion rate
names(baseline_conversion_rates) <- metrics_names

# create a dateframe that has a historical conversion rate for each user/metric combo
user_metric_crs <- expand.grid(user_id=unique(website_traffic$user_id),
                               metric_id=metrics_names,
                               stringsAsFactors = FALSE) %>%
    arrange(user_id, metric_id) %>%
    mutate(baseline_conversion_rate=baseline_conversion_rates[metric_id])

# now add experiment/variation columns for users that were part of experiments
user_metric_crs <- full_join(user_metric_crs,
          experiment_traffic %>% select(user_id, experiment_id, variation), by='user_id')

# based on experiment/variation/metric, get the chosen conversion rate
user_metric_crs <- left_join(user_metric_crs,
                             adjusted_conversion_rates %>% select(-baseline_conversion_rate),
                             by=c('experiment_id', 'variation', 'metric_id')) %>%
    mutate(conversion_rate=ifelse(is.na(adjusted_conversion_rate), baseline_conversion_rate, adjusted_conversion_rate)) %>%
    select(user_id, metric_id, conversion_rate)

# some people will have partipated in multiple experiments, so we'll take the average to get a dataset that is unique per user/metric
user_metric_crs <- user_metric_crs %>% 
    group_by(user_id, metric_id) %>%
    summarise(conversion_rate = mean(conversion_rate)) %>%
    ungroup()
# View(distinct(user_metric_crs %>% select(-user_id)))
stopifnot(length(unique(user_metric_crs$user_id)) == length(unique(website_traffic$user_id)))

# now we will determine if each person convertes based on their simulated conversion rate using the binomial distribution
# if we set the seed based on user-id, i see some odd behavior, so let's try assigned someone a random number that we will use as a seed
set.seed(1)
random_seeds <- sample(1:(max(user_metric_crs$user_id) * 2), max(user_metric_crs$user_id), replace=F)
simulate_conversion <- function(seed, conversion_rate) {
    set.seed(seed)
    #rbinom(1000, 1, 0.08)
    return (rbinom(1, 1, conversion_rate))
}

user_metric_crs <- user_metric_crs %>%
    mutate(seed = random_seeds[user_id])
stopifnot(!any(is.na(user_metric_crs$seed)))

# now we simulating them converting or not by using their assigned conversion rates as a probability in a binom distribution
user_metric_crs$converted <- as.logical(map2_dbl(user_metric_crs$seed,
                                                 user_metric_crs$conversion_rate, 
                                                 ~ simulate_conversion(.x, .y)))

plot_object <- user_metric_crs %>%
    count(metric_id, converted) %>%
    mutate(metric_id = factor(metric_id, levels=metrics_names)) %>%
    mutate(n = n / length(unique(user_metric_crs$user_id))) %>%
    ggplot(aes(x=metric_id, y=n, group=converted, fill=converted)) +
    geom_col(position='dodge') +
    geom_text(aes(label=percent(n))) +
    labs(title='Conversion Rates (among all users) for Each Metric',
         subtitle= "Doesn't account for the lag between first visit and the conversion date.")
plot_object %>% test_save_plot(file='simulated_data_plots/metric_conversion_rates_no_lag_consideration.png')

# create a dataset of the website traffic users that have converted
conversion_data <- inner_join(user_metric_crs %>%
                                  filter(converted) %>%
                                  select(user_id, metric_id),
                              website_traffic %>% 
                                  group_by(user_id) %>%
                                  summarise(first_visit=min(visit_date)),
                              by='user_id') %>%
    arrange(user_id, metric_id)
# View(conversion_data)

temp <- inner_join(
    inner_join(experiment_traffic, conversion_data, by='user_id') %>%
        #mutate(converted=!is.na(first_joined_experiment)) %>%
        count(experiment_id, variation, metric_id),
    experiment_traffic %>% count(experiment_id, variation),
    by=c('experiment_id', 'variation')) %>% 
    inner_join(experiment_info, by=c('experiment_id', 'variation'))

plot_object <- temp %>%
    mutate(cr=n.x/n.y) %>%
    arrange(experiment_id, metric_id, is_control) %>%
    mutate(metric_id=factor(metric_id, levels=metrics_names)) %>%
    ggplot(aes(x=metric_id, y=cr, group=is_control, fill=is_control)) +
    geom_col(position='dodge') +
    facet_wrap(~ experiment_id) +
    geom_text(aes(label=round(cr, 3)),
              position = position_dodge(width = 1), 
              size=3) +
    theme(axis.text.x = element_text(angle = 30, hjust = 1)) +
    labs(title='Conversion Rates Between Variations Per Metric')
plot_object %>% test_save_plot(file='simulated_data_plots/conversion_rates_of_experiments_per_variation.png')

plot_object <- temp %>%
    group_by(experiment_id, metric_id) %>%
    summarise(baseline_cr = n.x[is_control == TRUE] / n.y[is_control == TRUE],
              variant_cr= n.x[is_control == FALSE] / n.y[is_control == FALSE],
              percent_change_over_baseline= (variant_cr - baseline_cr) / baseline_cr) %>%
    ungroup() %>%
    mutate(experiment_id = factor(experiment_id, levels=experiment_names),
           metric_id=factor(metric_id, levels=metrics_names)) %>%
    ggplot(aes(x=metric_id, y=percent_change_over_baseline, fill=metric_id)) +
    geom_col(position='dodge') +
    geom_hline(yintercept = 0, color='red') +
    facet_wrap(~ experiment_id) +
    coord_cartesian(ylim = c(-0.15, 0.15)) +
    geom_text(aes(label=percent(percent_change_over_baseline)),
              position = position_dodge(width = 1), 
              size=3,
              vjust=-0.75) +
    theme(axis.text.x = element_text(angle = 30, hjust = 1)) +
    labs(title="% Change in CR from the Baseline (A) variation to the Variant (B)")
plot_object %>% test_save_plot(file='simulated_data_plots/percent_change_in_cr_of_experiments_per_variation.png')

##############################################################################################################
# For those who convert to a metric, generate the offset (number of days) from first-visit to conversion-date
##############################################################################################################

# if we set the seed based on user-id, i see some odd behavior, so let's try assigned someone a random number that we will use as a seed
num_seeds_needed <- max(conversion_data$user_id)
set.seed(2)
random_seeds <- sample(1:(num_seeds_needed * 2), num_seeds_needed, replace=F)
user_seeds <- random_seeds[conversion_data$user_id]
generate_offset <- function(user_seed, metric) {

    # NOTE setting the seed is messing up the distribution   
    set.seed(user_seed)
    # convert from 0-30 days, acnored by the attribution window
    rbinom(1, 30, attribution_windows_days[metric]/30)
}

names(attribution_windows_days) <- metrics_names
conversion_offsets_days <- map2_dbl(user_seeds, 
                               conversion_data$metric_id,
                               #~ rbinom(1, 30, attribution_windows_days[.y]/30))
                               ~ generate_offset(.x, .y))

# need to simulate time-stamps
set.seed(43)
conversion_offsets_seconds <- round(runif(length(conversion_offsets_days), min = 0, max=seconds_in_day - 1))

conversion_data$offset_days <- conversion_offsets_days
conversion_data$conversion_date <- as.POSIXct(conversion_data$first_visit + days(conversion_offsets_days) + seconds(conversion_offsets_seconds))

conversion_data <- conversion_data %>%
    filter(conversion_date <= max(website_traffic$visit_date))

plot_object <- conversion_data %>%
    count(metric_id, offset_days) %>%
    mutate(offset_days=factor(offset_days)) %>%
    mutate(metric_id=fct_reorder(metric_id, n, .desc = TRUE)) %>%
    ggplot(aes(x=offset_days, y=n)) +
        geom_col() +
    facet_wrap( ~ metric_id, scales = 'free_y') +
    labs(title='Distribution of Days from First Visit to Event Conversion, for those that convert')
plot_object %>% test_save_plot(file='simulated_data_plots/distro_days_from_first_visit_to_conversion_per_metric.png')

plot_object <- conversion_data %>%
    mutate(conversion_date = as.Date(conversion_date)) %>%
    count(conversion_date, metric_id) %>%
    ggplot(aes(x=conversion_date, y=n)) +
        geom_line() +
    facet_wrap( ~ metric_id, scales = 'free_y') +
    labs(title='Daily Conversions')
plot_object %>% test_save_plot(file='simulated_data_plots/daiy_conversion_events_per_metric.png')

conversion_data <- conversion_data %>%
    select(user_id, metric_id, conversion_date) %>%
    arrange(user_id, conversion_date)

check_data__conversion_events(conversion_data, attribution_windows)
write.csv(conversion_data, file='simulated_data/conversion_events.csv', row.names = FALSE)

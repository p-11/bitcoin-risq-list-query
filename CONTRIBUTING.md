# Contributing to BTC at Risk Query

We welcome contributions to improve the query that powers our BTC at Risk Tracker. Here's how you can help:

## How to Contribute

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/your-feature`)
3. Make your changes
4. Test your changes using BigQuery:
   - Sign up for Google Cloud Platform - the free tier includes 1TB of queries per month
   - We recommend using [BigQuery Studio](https://console.cloud.google.com/bigquery) - it provides a user-friendly interface for SQL development with features like syntax highlighting, query validation, and cost estimation
   - Update the destination table reference in the query to match your setup:
     ```sql
     CREATE OR REPLACE TABLE `your-project.your_dataset.your_table_name` AS
     ```
   - Start with a small data sample by setting lower cutoff values:
     ```sql
     DECLARE cutoff_month DATE DEFAULT '2011-01-01';  -- Early Bitcoin history
     DECLARE cutoff_block INT64 DEFAULT 100000;       -- First ~100k blocks
     ```
   - Once verified, test with a larger dataset by adjusting the cutoffs
   - Monitor your query costs using the query validator before running
5. Commit your changes (`git commit -am 'Add your feature'`)
6. Push to the branch (`git push origin feature/your-feature`)
7. Create a new Pull Request

## Query Guidelines

- Ensure your changes maintain or improve the query's performance
- Keep the query well-documented with clear comments
- Test changes with different block height and date ranges
- Maintain backward compatibility where possible

## Questions?

If you have questions about the query or need help with your contribution, please open an issue in the repository.

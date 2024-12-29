#!/bin/bash

# Set up color variables
YELLOW='\033[1;93m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Fetch GitHub Token from environment variable
if [[ -z "$PAT_TOKEN" ]]; then
    echo -e "${RED}Error: PAT_TOKEN environment variable is not set. Exiting.${NC}"
    exit 1
fi

GITHUB_TOKEN="$PAT_TOKEN"

# Start time for potential debugging
start_time=$(date +%s)

# Check rate limit
rate_limit_response=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
    "https://api.github.com/rate_limit")
remaining=$(echo "$rate_limit_response" | jq -r '.rate.remaining // 0')
reset_time=$(echo "$rate_limit_response" | jq -r '.rate.reset // 0')

if [[ "$remaining" -eq 0 ]]; then
    reset_time_human=$(date -d "@$reset_time" "+%Y-%m-%d %H:%M:%S")
    echo -e "${RED}Rate limit exceeded. Try again after: $reset_time_human${NC}"
    exit 1
fi

# We have 3 separate keywords
queries=("bugbounty" "bug-bounty" "bug bounty")

# Counters
final_repo_count=0  # Count of unique repos to show in README
highest_pages_processed=0  # Highest number of pages navigated for any query

# We'll track unique repos with a shell array
unique_repos=()

# Check if a string is already in the "unique_repos" array
function is_in_unique_repos() {
    local candidate="$1"
    for elem in "${unique_repos[@]}"; do
        if [[ "$elem" == "$candidate" ]]; then
            return 0  # found
        fi
    done
    return 1  # not found
}

# Remove any old README
rm -f README.md

cat <<EOF > README.md
# **BountyHound**

**BountyHound** is your **FULLY AUTOMATED WEEKLY (MONDAY) TRACKER** for top GitHub repositories related to **bug bounty**. By monitoring and curating trending repositories, BountyHound ensures you stay up-to-date with the latest tools, frameworks, and research in the bug bounty domain.

---

## **How It Works**

- **Automated Updates**: GitHub Actions automatically fetches and updates this list.
- **Key Metrics**: Repositories with their stars, forks, descriptions, and last updated date.

---

## **Summary of Today's Analysis**

| Metric                     | Value                   |
|----------------------------|-------------------------|
| Execution Date             | $(date '+%Y-%m-%d %H:%M:%S') |
| Repositories Analyzed      | <REPOS_ANALYZED>       |
| Pages Processed            | <PAGES_PROCESSED>      |

---

## **Top Bug Bounty Repositories (Updated: $(date '+%Y-%m-%d'))**

| Repository (Link) | Stars   | Forks   | Description                     | Last Updated |
|-------------------|---------|---------|---------------------------------|--------------|
EOF

# For consecutive empty pages per query
consecutive_empty=0

# Query function
fetch_and_append() {
    local query="$1"

    echo -e "${YELLOW}Fetching repos for: ${GREEN}${query}${NC}"

    # 1) First fetch small page to find total_count
    local initial_resp
    initial_resp=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
        "https://api.github.com/search/repositories?q=$(echo "$query" | sed 's/ /+/g')&sort=stars&order=desc&per_page=5")

    # Validate JSON
    if ! echo "$initial_resp" | jq -e . > /dev/null 2>&1; then
        echo -e "${RED}Error: Failed to fetch data for '$query'.${NC}"
        return
    fi

    local total_count
    total_count=$(echo "$initial_resp" | jq -r '.total_count // 0')
    if [[ "$total_count" -eq 0 ]]; then
        echo -e "${YELLOW}No repos found for '$query'.${NC}"
        return
    fi

    # Calculate how many pages (100 per page)
    local total_pages=$(( (total_count + 99) / 100 ))
    if [[ "$total_pages" -gt "$highest_pages_processed" ]]; then
        highest_pages_processed="$total_pages"
    fi
    consecutive_empty=0  # reset for this query

    # 2) Loop over pages
    for (( p=1; p<=total_pages; p++ )); do
        local resp
        resp=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
            "https://api.github.com/search/repositories?q=$(echo "$query" | sed 's/ /+/g')&sort=stars&order=desc&per_page=100&page=$p")

        local item_count
        item_count=$(echo "$resp" | jq '.items | length')
        if [[ "$item_count" -eq 0 || "$item_count" == "null" ]]; then
            consecutive_empty=$((consecutive_empty + 1))
            if [[ $consecutive_empty -ge 3 ]]; then
                echo -e "${YELLOW}3 consecutive empty pages for '$query'; skipping further pages.${NC}"
                break
            fi
            continue
        else
            consecutive_empty=0
        fi

        while read -r line; do
            local name owner stars forks desc updated url
            name=$(echo "$line" | jq -r '.name // "Unknown"')
            owner=$(echo "$line" | jq -r '.owner.login // "Unknown"')
            stars=$(echo "$line" | jq -r '.stargazers_count // 0')
            forks=$(echo "$line" | jq -r '.forks_count // 0')
            desc=$(echo "$line" | jq -r '.description // "No description"')
            updated=$(echo "$line" | jq -r '.updated_at // "1970-01-01T00:00:00Z"')
            url=$(echo "$line" | jq -r '.html_url // "#"')

            # Dedupe: check if "owner/name" is in unique_repos
            local repo_id="${owner}/${name}"
            if ! is_in_unique_repos "$repo_id"; then
                unique_repos+=( "$repo_id" )
                final_repo_count=$((final_repo_count + 1))

                # Abbreviate the description
                local short_desc
                short_desc=$(echo "$desc" | cut -c 1-50)
                if [ ${#desc} -gt 50 ]; then
                    short_desc="$short_desc..."
                fi

                # Convert date to YYYY-MM-DD
                local updated_date
                if [[ "$OSTYPE" == "darwin"* ]]; then
                    updated_date=$(echo "$updated" | \
                        awk '{print $1}' | \
                        xargs -I {} date -u -jf "%Y-%m-%dT%H:%M:%SZ" {} "+%Y-%m-%d")
                else
                    updated_date=$(date -d "$updated" "+%Y-%m-%d")
                fi

                # Append to README
                printf "| [%s](%s) | %-7s | %-7s | %-31s | %-12s |\n" \
                       "$name" "$url" "$stars" "$forks" "$short_desc" "$updated_date" \
                       >> README.md
            fi
        done < <(echo "$resp" | jq -c '.items[]')
    done
}

# Run each query, appending results
for kw in "${queries[@]}"; do
    fetch_and_append "$kw"
done

# Replace placeholders
sed -i "s/<REPOS_ANALYZED>/$final_repo_count/" README.md
sed -i "s/<PAGES_PROCESSED>/$highest_pages_processed/" README.md

# (Optional) Debug
echo "DEBUG: Unique Repositories Final Count: $final_repo_count"
echo "DEBUG: Highest Pages Processed        : $highest_pages_processed"

# Commit and push if README changed
if [ -s README.md ]; then
    git config --global user.email "github-actions@github.com"
    git config --global user.name "GitHub Actions Bot"
    git add README.md
    git commit -m "Update README with bug bounty repositories"
    git push origin main
fi

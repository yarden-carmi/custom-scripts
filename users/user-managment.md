# Linux & Git Management Cheat Sheet

## 🛠 Git: Modifying Commits
Commands for fixing mistakes or moving files between commits.

| Action | Command |
| :--- | :--- |
| **Add file to last commit** | `git add <file>` then `git commit --amend --no-edit` |
| **Move file to older commit** | `git add <file>`, `git commit --fixup <hash>`, then `git rebase -i --autosquash <hash>^` |
| **Undo last 2 commits (keep files)** | `git reset --soft HEAD~2` |

---

## 👤 User Management
Tools for listing, creating, and modifying system accounts.

### 🔍 Listing & Identification
* **List all human users:**
  `getent passwd | awk -F: '$3 >= 1000 {print $1}'`
  *Filters for UIDs of 1000 or greater, which typically represents actual users.*

* **List every username on the system:**
  `cut -d: -f1 /etc/passwd`
  *Extracts the username column from the system password database.*

* **Check a specific user's IDs:**
  `id USERNAME`
  *Shows the UID, GID, and all group memberships.*

### ➕ Adding & Modifying
* **Create a new user (Interactive):**
  `sudo adduser USERNAME`
  *Creates the account, home directory, and sets the password.*

* **Grant Admin (Sudo) privileges:**
  `sudo usermod -aG sudo USERNAME`
  *Appends the user to the sudo group.*

* **Change a user's password:**
  `sudo passwd USERNAME`

### ❌ Deletion & Monitoring
* **Delete user and their files:**
  `sudo deluser --remove-home USERNAME`
* **See who is currently logged in:**
  `w`
* **View login history:**
  `last`

---

## 📂 File Permissions & Ownership
Controlling who can read, write, or execute files.



### 1. Permission Breakdown
Permissions are represented by numbers or letters:
* **r** (read) = 4
* **w** (write) = 2
* **x** (execute) = 1

Example: `chmod 755` means **Owner** (4+2+1=7), **Group** (4+1=5), and **Others** (4+1=5).

### 2. Essential Commands

* **Change Owner:**
  `sudo chown USERNAME:GROUPNAME file.txt`
  *Changes which user and group own the file.*

* **Change Permissions (Numeric):**
  `chmod 644 file.txt`
  *Sets: Owner (Read/Write), Group (Read), Others (Read).*

* **Change Permissions (Symbolic):**
  `chmod +x script.sh`
  *Adds 'Execute' permission for the current owner.*

* **Recursive Ownership (Folders):**
  `sudo chown -R USERNAME:USERNAME /path/to/directory`
  *Applies ownership to the folder and every file inside it.*

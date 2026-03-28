// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title SplitwiseDeFi - On-Chain Expense Settlement
 * @notice Production-grade expense tracking and debt settlement system
 * @dev Implements secure debt tracking with ETH-based settlement
 */
contract SplitwiseDeFi {
    
    // ============ State Variables ============
    
    mapping(address => string) public names;
    mapping(address => mapping(address => uint256)) public debts;
    
    struct Expense {
        uint256 id;
        string description;
        address payer;
        uint256 amount;
        uint256 timestamp;
        address[] participants;
    }
    
    Expense[] public expenses;
    uint256 private expenseCounter;
    
    // ReentrancyGuard
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;
    uint256 private status = NOT_ENTERED;
    
    // ============ Events ============
    
    event NameSet(address indexed user, string name);
    event ExpenseAdded(
        uint256 indexed expenseId,
        address indexed payer,
        uint256 amount,
        string description,
        uint256 timestamp
    );
    event DebtPaid(
        address indexed debtor,
        address indexed creditor,
        uint256 amount,
        uint256 remainingDebt
    );
    
    // ============ Modifiers ============
    
    modifier nonReentrant() {
        require(status != ENTERED, "ReentrancyGuard: reentrant call");
        status = ENTERED;
        _;
        status = NOT_ENTERED;
    }
    
    // ============ Functions ============
    
    /**
     * @notice Set display name for the caller
     * @param _name Display name to set
     */
    function setName(string memory _name) external {
        require(bytes(_name).length > 0, "Name cannot be empty");
        require(bytes(_name).length <= 50, "Name too long");
        names[msg.sender] = _name;
        emit NameSet(msg.sender, _name);
    }
    
    /**
     * @notice Add a new expense and split among participants
     * @param description Expense description
     * @param amount Total expense amount in wei
     * @param participants Array of addresses to split expense with (including payer)
     */
    function addExpense(
        string memory description,
        uint256 amount,
        address[] memory participants
    ) external {
        require(bytes(description).length > 0, "Description required");
        require(amount > 0, "Amount must be greater than 0");
        require(participants.length > 0, "At least one participant required");
        require(participants.length <= 50, "Too many participants");
        
        // Verify payer is in participants
        bool payerIncluded = false;
        for (uint256 i = 0; i < participants.length; i++) {
            require(participants[i] != address(0), "Invalid participant address");
            if (participants[i] == msg.sender) {
                payerIncluded = true;
            }
        }
        require(payerIncluded, "Payer must be in participants");
        
        // Calculate share per person
        uint256 sharePerPerson = amount / participants.length;
        require(sharePerPerson > 0, "Amount too small to split");
        
        // Create expense record
        uint256 expenseId = expenseCounter++;
        expenses.push(Expense({
            id: expenseId,
            description: description,
            payer: msg.sender,
            amount: amount,
            timestamp: block.timestamp,
            participants: participants
        }));
        
        // Update debts - each participant owes payer their share
        // (except payer owes nothing to themselves)
        for (uint256 i = 0; i < participants.length; i++) {
            if (participants[i] != msg.sender) {
                debts[participants[i]][msg.sender] += sharePerPerson;
            }
        }
        
        emit ExpenseAdded(expenseId, msg.sender, amount, description, block.timestamp);
    }
    
    /**
     * @notice Pay debt to a creditor
     * @param creditor Address to pay debt to
     * @dev Accepts ETH payment and reduces debt accordingly
     */
    function payDebt(address creditor) external payable nonReentrant {
        require(creditor != address(0), "Invalid creditor address");
        require(creditor != msg.sender, "Cannot pay debt to yourself");
        require(msg.value > 0, "Payment amount must be greater than 0");
        
        uint256 currentDebt = debts[msg.sender][creditor];
        require(currentDebt > 0, "No debt owed to this creditor");
        require(msg.value <= currentDebt, "Payment exceeds debt amount");
        
        // Effects: Update debt before external call
        uint256 newDebt = currentDebt - msg.value;
        debts[msg.sender][creditor] = newDebt;
        
        emit DebtPaid(msg.sender, creditor, msg.value, newDebt);
        
        // Interactions: Transfer ETH to creditor
        (bool success, ) = creditor.call{value: msg.value}("");
        require(success, "ETH transfer failed");
    }
    
    // ============ View Functions ============
    
    /**
     * @notice Get debt amount between two addresses
     * @param debtor Address that owes money
     * @param creditor Address that is owed money
     * @return Debt amount in wei
     */
    function getDebtBetween(address debtor, address creditor) 
        external 
        view 
        returns (uint256) 
    {
        return debts[debtor][creditor];
    }
    
    /**
     * @notice Get all debts owed by caller
     * @return creditors Array of addresses caller owes money to
     * @return amounts Array of amounts owed to each creditor
     */
    function getMyDebts() 
        external 
        view 
        returns (address[] memory creditors, uint256[] memory amounts) 
    {
        // First pass: count non-zero debts
        uint256 count = 0;
        for (uint256 i = 0; i < expenses.length; i++) {
            address payer = expenses[i].payer;
            if (payer != msg.sender && debts[msg.sender][payer] > 0) {
                count++;
            }
            // Check all participants as potential creditors
            for (uint256 j = 0; j < expenses[i].participants.length; j++) {
                address participant = expenses[i].participants[j];
                if (participant != msg.sender && debts[msg.sender][participant] > 0) {
                    // Check if already counted
                    bool alreadyCounted = false;
                    if (participant == payer) alreadyCounted = true;
                    if (!alreadyCounted) count++;
                }
            }
        }
        
        creditors = new address[](count);
        amounts = new uint256[](count);
        
        // Second pass: populate arrays
        uint256 index = 0;
        address[] memory seen = new address[](count);
        
        for (uint256 i = 0; i < expenses.length; i++) {
            address payer = expenses[i].payer;
            if (payer != msg.sender && debts[msg.sender][payer] > 0) {
                bool alreadyAdded = false;
                for (uint256 k = 0; k < index; k++) {
                    if (seen[k] == payer) {
                        alreadyAdded = true;
                        break;
                    }
                }
                if (!alreadyAdded) {
                    creditors[index] = payer;
                    amounts[index] = debts[msg.sender][payer];
                    seen[index] = payer;
                    index++;
                }
            }
        }
        
        return (creditors, amounts);
    }
    
    /**
     * @notice Get all debts owed to caller
     * @return debtors Array of addresses that owe caller money
     * @return amounts Array of amounts owed by each debtor
     */
    function getMyCredits() 
        external 
        view 
        returns (address[] memory debtors, uint256[] memory amounts) 
    {
        // First pass: count non-zero credits
        uint256 count = 0;
        for (uint256 i = 0; i < expenses.length; i++) {
            for (uint256 j = 0; j < expenses[i].participants.length; j++) {
                address participant = expenses[i].participants[j];
                if (participant != msg.sender && debts[participant][msg.sender] > 0) {
                    count++;
                }
            }
        }
        
        debtors = new address[](count);
        amounts = new uint256[](count);
        
        // Second pass: populate arrays
        uint256 index = 0;
        address[] memory seen = new address[](count);
        
        for (uint256 i = 0; i < expenses.length; i++) {
            for (uint256 j = 0; j < expenses[i].participants.length; j++) {
                address participant = expenses[i].participants[j];
                if (participant != msg.sender && debts[participant][msg.sender] > 0) {
                    bool alreadyAdded = false;
                    for (uint256 k = 0; k < index; k++) {
                        if (seen[k] == participant) {
                            alreadyAdded = true;
                            break;
                        }
                    }
                    if (!alreadyAdded) {
                        debtors[index] = participant;
                        amounts[index] = debts[participant][msg.sender];
                        seen[index] = participant;
                        index++;
                    }
                }
            }
        }
        
        return (debtors, amounts);
    }
    
    /**
     * @notice Get total number of expenses
     * @return Total expense count
     */
    function getExpenseCount() external view returns (uint256) {
        return expenses.length;
    }
    
    /**
     * @notice Get expense details by ID
     * @param expenseId ID of the expense
     * @return Expense struct
     */
    function getExpense(uint256 expenseId) 
        external 
        view 
        returns (Expense memory) 
    {
        require(expenseId < expenses.length, "Expense does not exist");
        return expenses[expenseId];
    }
}

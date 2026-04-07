// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * ███████╗ ██████╗ ██████╗ ███╗   ███╗    ██╗ ██████╗  ██████╗  ██████╗       ███╗   ██╗███████╗████████╗
 * ██╔════╝██╔═══██╗██╔══██╗████╗ ████║    ██║██╔═████╗██╔════╝ ██╔════╝       ████╗  ██║██╔════╝╚══██╔══╝
 * █████╗  ██║   ██║██████╔╝██╔████╔██║    ██║██║██╔██║██║  ███╗██║  ███╗█████╗██╔██╗ ██║█████╗     ██║
 * ██╔══╝  ██║   ██║██╔══██╗██║╚██╔╝██║    ██║████╔╝██║██║   ██║██║   ██║╚════╝██║╚██╗██║██╔══╝     ██║
 * ██║     ╚██████╔╝██║  ██║██║ ╚═╝ ██║    ██║╚██████╔╝╚██████╔╝╚██████╔╝      ██║ ╚████║██║        ██║
 * ╚═╝      ╚═════╝ ╚═╝  ╚═╝╚═╝     ╚═╝    ╚═╝ ╚═════╝  ╚═════╝  ╚═════╝       ╚═╝  ╚═══╝╚═╝        ╚═╝
 *
 * @title   Form1099NFT
 * @notice  1,000 unique NFTs on Arbitrum One. Tax season, on-chain.
 *          0.001 ETH mint price. 1 per wallet. 1,000 max supply.
 *
 * @dev     ERC-721 with:
 *          - Sequential token IDs (1 → 1000)
 *          - On-chain supply cap
 *          - 1 per wallet enforcement
 *          - Reveal mechanism (pre-reveal placeholder URI → post-reveal baseURI)
 *          - Owner withdraw
 *          - Royalties (ERC-2981)
 */

interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

interface IERC721 {
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    function balanceOf(address owner) external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external;
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function transferFrom(address from, address to, uint256 tokenId) external;
    function approve(address to, uint256 tokenId) external;
    function setApprovalForAll(address operator, bool approved) external;
    function getApproved(uint256 tokenId) external view returns (address);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
}

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) external returns (bytes4);
}

interface IERC2981 {
    function royaltyInfo(uint256 tokenId, uint256 salePrice) external view returns (address receiver, uint256 royaltyAmount);
}

contract Form1099NFT is IERC165, IERC721, IERC2981 {

    // ── Collection Config ─────────────────────────────────────────────────────
    string  public constant name     = "Form 1099-NFT";
    string  public constant symbol   = "1099";
    uint256 public constant MAX_SUPPLY   = 1000;
    uint256 public constant MINT_PRICE   = 0.001 ether;
    uint256 public constant MAX_PER_WALLET = 1;

    // ── State ─────────────────────────────────────────────────────────────────
    address public owner;
    uint256 public totalSupply;
    bool    public mintActive;
    bool    public revealed;

    string  private _baseURI;         // set after reveal (IPFS folder URI)
    string  private _placeholderURI;  // shown before reveal

    uint96  private _royaltyBps = 500; // 5% royalty

    // ── ERC-721 Storage ───────────────────────────────────────────────────────
    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;
    mapping(address => bool) public hasMinted;

    // ── Events ────────────────────────────────────────────────────────────────
    event Minted(address indexed to, uint256 indexed tokenId);
    event Revealed(string baseURI);
    event MintToggled(bool active);
    event Withdrawn(address to, uint256 amount);
    event OwnershipTransferred(address indexed from, address indexed to);

    // ── Errors ────────────────────────────────────────────────────────────────
    error NotOwner();
    error MintNotActive();
    error SoldOut();
    error AlreadyMinted();
    error WrongPrice();
    error ZeroAddress();
    error NotTokenOwner();
    error NotApproved();
    error NonexistentToken();
    error NotERC721Receiver();
    error WithdrawFailed();

    // ── Constructor ───────────────────────────────────────────────────────────
    constructor(string memory placeholderURI_) {
        owner           = msg.sender;
        _placeholderURI = placeholderURI_;
    }

    // ── Modifiers ─────────────────────────────────────────────────────────────
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ── MINT ──────────────────────────────────────────────────────────────────

    /**
     * @notice Mint one Form 1099-NFT. 0.001 ETH. One per wallet. Forever.
     */
    function mint() external payable {
        if (!mintActive)                    revert MintNotActive();
        if (totalSupply >= MAX_SUPPLY)      revert SoldOut();
        if (hasMinted[msg.sender])          revert AlreadyMinted();
        if (msg.value != MINT_PRICE)        revert WrongPrice();

        hasMinted[msg.sender] = true;
        totalSupply++;
        uint256 tokenId = totalSupply;

        _owners[tokenId]   = msg.sender;
        _balances[msg.sender]++;

        emit Transfer(address(0), msg.sender, tokenId);
        emit Minted(msg.sender, tokenId);
    }

    /**
     * @notice Owner can airdrop up to 20 tokens at once (for giveaways/team).
     *         Does NOT enforce hasMinted — owner manages recipients manually.
     */
    function airdrop(address[] calldata recipients) external onlyOwner {
        require(recipients.length <= 20, "Max 20 per airdrop");
        require(totalSupply + recipients.length <= MAX_SUPPLY, "Exceeds supply");
        for (uint256 i = 0; i < recipients.length; i++) {
            if (recipients[i] == address(0)) revert ZeroAddress();
            totalSupply++;
            uint256 tokenId = totalSupply;
            _owners[tokenId]          = recipients[i];
            _balances[recipients[i]]++;
            hasMinted[recipients[i]]  = true;
            emit Transfer(address(0), recipients[i], tokenId);
            emit Minted(recipients[i], tokenId);
        }
    }

    // ── METADATA ──────────────────────────────────────────────────────────────

    /**
     * @notice Returns token metadata URI.
     *         Before reveal: returns placeholder for all tokens.
     *         After reveal:  returns baseURI + tokenId + ".json"
     */
    function tokenURI(uint256 tokenId) external view returns (string memory) {
        if (_owners[tokenId] == address(0)) revert NonexistentToken();
        if (!revealed) return _placeholderURI;
        return string(abi.encodePacked(_baseURI, _toString(tokenId), ".json"));
    }

    // ── OWNER FUNCTIONS ───────────────────────────────────────────────────────

    /** @notice Start or pause minting. */
    function toggleMint(bool active) external onlyOwner {
        mintActive = active;
        emit MintToggled(active);
    }

    /**
     * @notice Reveal the collection by setting the IPFS base URI.
     *         Call after all metadata is uploaded to IPFS.
     *         URI format: "ipfs://YOUR_CID/"
     */
    function reveal(string calldata baseURI_) external onlyOwner {
        _baseURI = baseURI_;
        revealed = true;
        emit Revealed(baseURI_);
    }

    /** @notice Update placeholder URI before reveal. */
    function setPlaceholderURI(string calldata uri) external onlyOwner {
        _placeholderURI = uri;
    }

    /** @notice Set royalty percentage (in basis points, max 10%). */
    function setRoyalty(uint96 bps) external onlyOwner {
        require(bps <= 1000, "Max 10%");
        _royaltyBps = bps;
    }

    /** @notice Withdraw all ETH from mints to owner wallet. */
    function withdraw() external onlyOwner {
        uint256 bal = address(this).balance;
        (bool ok,) = owner.call{value: bal}("");
        if (!ok) revert WithdrawFailed();
        emit Withdrawn(owner, bal);
    }

    /** @notice Transfer contract ownership. */
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // ── ERC-2981 ROYALTIES ────────────────────────────────────────────────────

    function royaltyInfo(uint256, uint256 salePrice)
        external view override
        returns (address receiver, uint256 royaltyAmount)
    {
        return (owner, (salePrice * _royaltyBps) / 10000);
    }

    // ── ERC-721 ───────────────────────────────────────────────────────────────

    function balanceOf(address owner_) external view returns (uint256) {
        if (owner_ == address(0)) revert ZeroAddress();
        return _balances[owner_];
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address o = _owners[tokenId];
        if (o == address(0)) revert NonexistentToken();
        return o;
    }

    function approve(address to, uint256 tokenId) external {
        address o = _owners[tokenId];
        if (o == address(0)) revert NonexistentToken();
        if (msg.sender != o && !_operatorApprovals[o][msg.sender]) revert NotApproved();
        _tokenApprovals[tokenId] = to;
        emit Approval(o, to, tokenId);
    }

    function getApproved(uint256 tokenId) external view returns (address) {
        if (_owners[tokenId] == address(0)) revert NonexistentToken();
        return _tokenApprovals[tokenId];
    }

    function setApprovalForAll(address operator, bool approved) external {
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function isApprovedForAll(address owner_, address operator) external view returns (bool) {
        return _operatorApprovals[owner_][operator];
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        if (to == address(0)) revert ZeroAddress();
        address o = _owners[tokenId];
        if (o == address(0)) revert NonexistentToken();
        if (o != from) revert NotTokenOwner();
        if (msg.sender != o && msg.sender != _tokenApprovals[tokenId] && !_operatorApprovals[o][msg.sender])
            revert NotApproved();
        delete _tokenApprovals[tokenId];
        _balances[from]--;
        _balances[to]++;
        _owners[tokenId] = to;
        emit Transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        safeTransferFrom(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public {
        transferFrom(from, to, tokenId);
        if (to.code.length > 0) {
            try IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data) returns (bytes4 ret) {
                if (ret != IERC721Receiver.onERC721Received.selector) revert NotERC721Receiver();
            } catch {
                revert NotERC721Receiver();
            }
        }
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == type(IERC165).interfaceId  ||
            interfaceId == type(IERC721).interfaceId  ||
            interfaceId == type(IERC2981).interfaceId;
    }

    // ── UTILS ─────────────────────────────────────────────────────────────────

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) { digits++; temp /= 10; }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits--;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}

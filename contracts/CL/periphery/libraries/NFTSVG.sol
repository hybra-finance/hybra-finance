// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.7.6;

import "contracts/core/libraries/TickMath.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "base64-sol/base64.sol";

/// @title NFTSVG
/// @notice Provides a function for generating an SVG associated with a CL NFT
library NFTSVG {
    using Strings for uint256;
    using SafeMath for uint256;

    function generateSVG(
        string memory quoteTokenSymbol,
        string memory baseTokenSymbol,
        uint256 quoteTokensOwed,
        uint256 baseTokensOwed,
        uint256 tokenId,
        int24 tickLower,
        int24 tickUpper,
        int24 tickSpacing,
        uint8 quoteTokenDecimals,
        uint8 baseTokenDecimals
    ) public pure returns (string memory svg) {
        return string(
            abi.encodePacked(
                '<svg width="800" height="800" viewBox="0 0 800 800" fill="none" xmlns="http://www.w3.org/2000/svg">',
                '<g id="NFT Aero" clip-path="url(#clip0_1098_820)">',
                '<rect width="800" height="800" fill="#252525"/>',
                '<g id="shadow">',
                '<g id="Group 465">',
                '<path id="Rectangle 173" d="M394 234L394 566L-0.000117372 566L-0.00012207 234L394 234Z" fill="url(#paint0_linear_1098_820)"/>',
                "</g>",
                "</g>",
                generateTopText({
                    quoteTokenSymbol: quoteTokenSymbol,
                    baseTokenSymbol: baseTokenSymbol,
                    tokenId: tokenId,
                    tickSpacing: tickSpacing
                }),
                generateArt(),
                generateBottomText({
                    quoteTokenSymbol: quoteTokenSymbol,
                    baseTokenSymbol: baseTokenSymbol,
                    quoteTokensOwed: quoteTokensOwed,
                    baseTokensOwed: baseTokensOwed,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    quoteTokenDecimals: quoteTokenDecimals,
                    baseTokenDecimals: baseTokenDecimals
                }),
                generateSVGDefs(),
                "</svg>"
            )
        );
    }

    function generateTopText(
        string memory quoteTokenSymbol,
        string memory baseTokenSymbol,
        uint256 tokenId,
        int24 tickSpacing
    ) private pure returns (string memory svg) {
        string memory poolId =
            string(abi.encodePacked("CL", tickToString(tickSpacing), "-", quoteTokenSymbol, "/", baseTokenSymbol));
        string memory tokenIdStr = string(abi.encodePacked("ID #", tokenId.toString()));
        string memory id = string(abi.encodePacked(poolId, tokenIdStr));
        svg = string(
            abi.encodePacked(
                '<g id="',
                id,
                '">',
                '<text fill="#F3F4F6" xml:space="preserve" style="white-space: pre" font-family="Arial" font-size="32" font-weight="bold" letter-spacing="0em"><tspan x="56" y="85.5938">',
                poolId,
                "</tspan></text>",
                "</g>",
                '<text id="ID #1223" fill="#F3F4F6" xml:space="preserve" style="white-space: pre" font-family="Arial" font-size="20" letter-spacing="0em">',
                '<tspan x="56" y="128.913">',
                tokenIdStr,
                "</tspan>",
                "</text>"
            )
        );
    }

    function generateArt() private pure returns (string memory svg) {
        svg = string(
            abi.encodePacked(
                '<circle id="circle" cx="400" cy="399.837" r="165.837" fill="#044FEB"/>',
                '<g id="aero"><g id="AERODROME">',
                '<path d="M305.685 409.746L303.986 405.868H293.765L292.066 409.746H285.186L294.416 389.927H303.335L312.537 409.746H305.685ZM295.747 401.394H302.004L298.89 394.288L295.747 401.394Z" fill="white"/>',
                '<path d="M334.374 394.769H319.652V397.713H334.374V401.96H319.652V404.905H334.374V409.746H313.423V389.927H334.374V394.769Z" fill="white"/>'
                '<path d="M358.868 397.345C358.868 400.403 357.396 402.81 354.989 403.971L358.557 409.746H351.195L348.251 404.792H341.937V409.746H335.708V389.927H351.28C355.782 389.927 358.868 392.929 358.868 397.345ZM341.937 395.194V399.525H349.865C351.026 399.525 352.639 399.525 352.639 397.345C352.639 395.194 351.026 395.194 349.865 395.194H341.937Z" fill="white"/>',
                '<path d="M372.297 410.03C363.577 410.03 359.839 406.547 359.839 399.809C359.839 393.098 363.577 389.644 372.297 389.644C380.989 389.644 384.755 393.127 384.755 399.809C384.755 406.519 380.989 410.03 372.297 410.03ZM372.297 404.763C377.139 404.763 378.526 402.866 378.526 399.809C378.526 396.779 377.167 394.91 372.297 394.91C367.456 394.91 366.068 396.751 366.068 399.809C366.068 402.895 367.484 404.763 372.297 404.763Z" fill="white"/>',
                '<path d="M400.666 389.927C405.593 389.927 410.095 393.098 410.095 399.837C410.095 406.575 405.593 409.746 400.666 409.746H386.085V389.927H400.666ZM398.543 404.48C401.261 404.48 403.866 404.084 403.866 399.837C403.866 395.59 401.261 395.194 398.543 395.194H392.314V404.48H398.543Z" fill="white"/>',
                '<path d="M434.6 397.345C434.6 400.403 433.127 402.81 430.721 403.971L434.288 409.746H426.927L423.982 404.792H417.668V409.746H411.44V389.927H427.012C431.513 389.927 434.6 392.929 434.6 397.345ZM417.668 395.194V399.525H425.596C426.757 399.525 428.371 399.525 428.371 397.345C428.371 395.194 426.757 395.194 425.596 395.194H417.668Z" fill="white"/>',
                '<path d="M448.028 410.03C439.308 410.03 435.571 406.547 435.571 399.809C435.571 393.098 439.308 389.644 448.028 389.644C456.72 389.644 460.486 393.127 460.486 399.809C460.486 406.519 456.72 410.03 448.028 410.03ZM448.028 404.763C452.87 404.763 454.257 402.866 454.257 399.809C454.257 396.779 452.898 394.91 448.028 394.91C443.187 394.91 441.8 396.751 441.8 399.809C441.8 402.895 443.215 404.763 448.028 404.763Z" fill="white"/>',
                '<path d="M492.168 389.927V409.746H485.939V398.195L479.116 409.746H474.869L468.045 398.166V409.746H461.817V389.927H469.801L477.021 402.583L484.212 389.927H492.168Z" fill="white"/>',
                '<path d="M514.814 394.769H500.091V397.713H514.814V401.96H500.091V404.905H514.814V409.746H493.862V389.927H514.814V394.769Z" fill="white"/>'
                "</g>",
                "</g>"
            )
        );
    }

    function generateSVGDefs() private pure returns (string memory svg) {
        svg = string(
            abi.encodePacked(
                "<defs>",
                '<linearGradient id="paint0_linear_1098_820" x1="491" y1="566" x2="26.2101" y2="566" gradientUnits="userSpaceOnUse">'
                '<stop offset="0.142" stop-color="white" stop-opacity="0.2"/>',
                '<stop offset="1" stop-opacity="0"/>',
                "</linearGradient>",
                '<clipPath id="clip0_1098_820">',
                '<rect width="800" height="800" fill="white"/>',
                "</clipPath>",
                "</defs>"
            )
        );
    }

    function generateBottomText(
        string memory quoteTokenSymbol,
        string memory baseTokenSymbol,
        uint256 quoteTokensOwed,
        uint256 baseTokensOwed,
        int24 tickLower,
        int24 tickUpper,
        uint8 quoteTokenDecimals,
        uint8 baseTokenDecimals
    ) internal pure returns (string memory svg) {
        string memory balance0 = balanceToDecimals(quoteTokensOwed, quoteTokenDecimals);
        string memory balance1 = balanceToDecimals(baseTokensOwed, baseTokenDecimals);
        string memory balances =
            string(abi.encodePacked(balance0, " ", quoteTokenSymbol, " ~ ", balance1, " ", baseTokenSymbol));
        string memory tickLow = string(abi.encodePacked(tickToString(tickLower), " Low "));
        string memory tickHigh = string(abi.encodePacked(tickToString(tickUpper), " High "));
        svg = string(
            abi.encodePacked(
                '<text id="',
                balances,
                '" fill="#F3F4F6" xml:space="preserve" style="white-space: pre" font-family="Arial" font-size="32" font-weight="bold" letter-spacing="0em"><tspan x="56" y="676.594">',
                balances,
                "</tspan></text>",
                '<rect id="line" opacity="0.05" x="56" y="700" width="693" height="2" fill="#D9D9D9"/>',
                '<text id="',
                tickLow,
                "&#226;&#128;&#148; ",
                tickHigh,
                '" fill="#F3F4F6" xml:space="preserve" style="white-space: pre" font-family="Arial" font-size="20" letter-spacing="0em"><tspan x="56" y="736.434">',
                tickLow,
                "&#x2014; ",
                tickHigh,
                "</tspan></text>",
                "</g>"
            )
        );
    }

    function balanceToDecimals(uint256 balance, uint8 decimals) private pure returns (string memory) {
        uint256 divisor = 10 ** decimals;
        uint256 integerPart = balance / divisor;
        uint256 fractionalPart = balance % divisor;

        // trim to 5 dp
        if (decimals > 5) {
            uint256 adjustedDivisor = 10 ** (decimals - 5);
            fractionalPart = adjustedDivisor > 0 ? fractionalPart / adjustedDivisor : fractionalPart;
        }

        // add leading zeroes
        string memory leadingZeros = "";
        uint256 fractionalPartLength = bytes(fractionalPart.toString()).length;
        uint256 zerosToAdd = 5 > fractionalPartLength ? 5 - fractionalPartLength : 0;
        for (uint256 i = 0; i < zerosToAdd; i++) {
            leadingZeros = string(abi.encodePacked("0", leadingZeros));
        }
        return string(abi.encodePacked(integerPart.toString(), ".", leadingZeros, fractionalPart.toString()));
    }

    function tickToString(int24 tick) private pure returns (string memory) {
        string memory sign = "";
        if (tick < 0) {
            tick = tick * -1;
            sign = "-";
        }
        return string(abi.encodePacked(sign, uint256(tick).toString()));
    }
}

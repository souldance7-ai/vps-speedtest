function ConvertTo-XlsxColumnName {
    param([int]$Index)
    $name = ""
    while ($Index -gt 0) {
        $Index--
        $name = [char](65 + ($Index % 26)) + $name
        $Index = [Math]::Floor($Index / 26)
    }
    return $name
}

function ConvertTo-XlsxCellXml {
    param([object]$Value, [string]$Reference, [int]$Style)
    if ($null -eq $Value) { return "<c r=`"$Reference`" s=`"$Style`"/>" }
    $typeCode = [System.Type]::GetTypeCode($Value.GetType())
    if ($typeCode -in @(
        [System.TypeCode]::Byte, [System.TypeCode]::SByte,
        [System.TypeCode]::Int16, [System.TypeCode]::UInt16,
        [System.TypeCode]::Int32, [System.TypeCode]::UInt32,
        [System.TypeCode]::Int64, [System.TypeCode]::UInt64,
        [System.TypeCode]::Single, [System.TypeCode]::Double,
        [System.TypeCode]::Decimal
    )) {
        $number = [System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture)
        return "<c r=`"$Reference`" s=`"$Style`"><v>$number</v></c>"
    }
    $text = [System.Security.SecurityElement]::Escape([string]$Value)
    return "<c r=`"$Reference`" t=`"inlineStr`" s=`"$Style`"><is><t xml:space=`"preserve`">$text</t></is></c>"
}

function Write-LazyVpsXlsx {
    param(
        [System.Collections.IDictionary]$Sheets,
        [string]$Path
    )
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $temp = Join-Path $env:TEMP ("lazyvps-xlsx-" + [guid]::NewGuid().ToString("N"))
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    try {
        New-Item -ItemType Directory -Force -Path (Join-Path $temp "_rels") | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $temp "xl\_rels") | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $temp "xl\worksheets") | Out-Null

        $sheetNames = @($Sheets.Keys)
        $contentTypes = New-Object System.Text.StringBuilder
        [void]$contentTypes.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>')
        $workbookSheets = New-Object System.Text.StringBuilder
        $workbookRels = New-Object System.Text.StringBuilder

        for ($sheetIndex = 0; $sheetIndex -lt $sheetNames.Count; $sheetIndex++) {
            $sheetNumber = $sheetIndex + 1
            $sheetName = [string]$sheetNames[$sheetIndex]
            $safeSheetName = [System.Security.SecurityElement]::Escape($sheetName)
            $rows = @($Sheets[$sheetName])
            if ($rows.Count -gt 0) { $headers = @($rows[0].PSObject.Properties.Name) }
            else { $headers = @("Status") }
            $lastColumn = ConvertTo-XlsxColumnName $headers.Count
            $lastRow = [Math]::Max(2, $rows.Count + 2)

            $xml = New-Object System.Text.StringBuilder
            [void]$xml.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">')
            [void]$xml.Append("<dimension ref=`"A1:$lastColumn$lastRow`"/><sheetViews><sheetView workbookViewId=`"0`"><pane ySplit=`"2`" topLeftCell=`"A3`" activePane=`"bottomLeft`" state=`"frozen`"/></sheetView></sheetViews><sheetFormatPr defaultRowHeight=`"20`"/>")
            [void]$xml.Append('<cols>')
            for ($columnIndex = 0; $columnIndex -lt $headers.Count; $columnIndex++) {
                $header = [string]$headers[$columnIndex]
                $width = if ($header -match 'Node|Service|Url|ISP|Message|Description') { 42 } elseif ($header -match 'Time|Expected|Country|Status') { 20 } else { 16 }
                $columnNumber = $columnIndex + 1
                [void]$xml.Append("<col min=`"$columnNumber`" max=`"$columnNumber`" width=`"$width`" customWidth=`"1`"/>")
            }
            [void]$xml.Append('</cols><sheetData>')
            [void]$xml.Append("<row r=`"1`" ht=`"30`" customHeight=`"1`"><c r=`"A1`" t=`"inlineStr`" s=`"1`"><is><t>LAZYVPS // $safeSheetName</t></is></c></row>")
            [void]$xml.Append('<row r="2" ht="24" customHeight="1">')
            for ($columnIndex = 0; $columnIndex -lt $headers.Count; $columnIndex++) {
                $reference = (ConvertTo-XlsxColumnName ($columnIndex + 1)) + "2"
                [void]$xml.Append((ConvertTo-XlsxCellXml -Value $headers[$columnIndex] -Reference $reference -Style 2))
            }
            [void]$xml.Append('</row>')

            for ($rowIndex = 0; $rowIndex -lt $rows.Count; $rowIndex++) {
                $excelRow = $rowIndex + 3
                $style = if ($rowIndex % 2 -eq 0) { 3 } else { 4 }
                [void]$xml.Append("<row r=`"$excelRow`">")
                for ($columnIndex = 0; $columnIndex -lt $headers.Count; $columnIndex++) {
                    $reference = (ConvertTo-XlsxColumnName ($columnIndex + 1)) + $excelRow
                    $value = $rows[$rowIndex].PSObject.Properties[$headers[$columnIndex]].Value
                    [void]$xml.Append((ConvertTo-XlsxCellXml -Value $value -Reference $reference -Style $style))
                }
                [void]$xml.Append('</row>')
            }
            if ($rows.Count -eq 0) { [void]$xml.Append('<row r="3"><c r="A3" t="inlineStr" s="3"><is><t>No data in this run</t></is></c></row>') }
            [void]$xml.Append("</sheetData><autoFilter ref=`"A2:$lastColumn$lastRow`"/><mergeCells count=`"1`"><mergeCell ref=`"A1:$($lastColumn)1`"/></mergeCells><pageMargins left=`"0.25`" right=`"0.25`" top=`"0.5`" bottom=`"0.5`" header=`"0.2`" footer=`"0.2`"/></worksheet>")
            [System.IO.File]::WriteAllText((Join-Path $temp "xl\worksheets\sheet$sheetNumber.xml"), $xml.ToString(), $utf8)

            [void]$contentTypes.Append("<Override PartName=`"/xl/worksheets/sheet$sheetNumber.xml`" ContentType=`"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml`"/>")
            [void]$workbookSheets.Append("<sheet name=`"$safeSheetName`" sheetId=`"$sheetNumber`" r:id=`"rId$sheetNumber`"/>")
            [void]$workbookRels.Append("<Relationship Id=`"rId$sheetNumber`" Type=`"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet`" Target=`"worksheets/sheet$sheetNumber.xml`"/>")
        }

        [void]$contentTypes.Append('</Types>')
        [System.IO.File]::WriteAllText((Join-Path $temp "[Content_Types].xml"), $contentTypes.ToString(), $utf8)
        [System.IO.File]::WriteAllText((Join-Path $temp "_rels\.rels"), '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>', $utf8)
        $workbookXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><bookViews><workbookView/></bookViews><sheets>' + $workbookSheets.ToString() + '</sheets></workbook>'
        [System.IO.File]::WriteAllText((Join-Path $temp "xl\workbook.xml"), $workbookXml, $utf8)
        [void]$workbookRels.Append('<Relationship Id="rId999" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>')
        [System.IO.File]::WriteAllText((Join-Path $temp "xl\_rels\workbook.xml.rels"), ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' + $workbookRels.ToString()), $utf8)

        $styles = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="3"><font><sz val="10"/><name val="Microsoft JhengHei"/><color rgb="FFE2E8F0"/></font><font><b/><sz val="16"/><name val="Microsoft JhengHei"/><color rgb="FFFFFFFF"/></font><font><b/><sz val="10"/><name val="Microsoft JhengHei"/><color rgb="FF07111F"/></font></fonts><fills count="6"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF0B5FA5"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FF22D3EE"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FF101D33"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FF162641"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="2"><border/><border><left style="thin"><color rgb="FF31425C"/></left><right style="thin"><color rgb="FF31425C"/></right><top style="thin"><color rgb="FF31425C"/></top><bottom style="thin"><color rgb="FF31425C"/></bottom></border></borders><cellStyleXfs count="1"><xf/></cellStyleXfs><cellXfs count="5"><xf fontId="0" fillId="0" borderId="0"/><xf fontId="1" fillId="2" borderId="0" applyFont="1" applyFill="1" applyAlignment="1"><alignment horizontal="left" vertical="center"/></xf><xf fontId="2" fillId="3" borderId="1" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center"/></xf><xf fontId="0" fillId="4" borderId="1" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment vertical="center"/></xf><xf fontId="0" fillId="5" borderId="1" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment vertical="center"/></xf></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>'
        [System.IO.File]::WriteAllText((Join-Path $temp "xl\styles.xml"), $styles, $utf8)

        if (Test-Path $Path) { Remove-Item $Path -Force }
        $archive = [System.IO.Compression.ZipFile]::Open($Path, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($file in Get-ChildItem -LiteralPath $temp -File -Recurse) {
                # Use explicit characters: Windows PowerShell can otherwise select a
                # surprising string overload and preserve backslashes in ZIP names.
                $relative = $file.FullName.Substring($temp.Length).TrimStart([char]92, [char]47).Replace([char]92, [char]47)
                $entry = $archive.CreateEntry($relative, [System.IO.Compression.CompressionLevel]::Optimal)
                $entryStream = $entry.Open()
                $fileStream = [System.IO.File]::OpenRead($file.FullName)
                try { $fileStream.CopyTo($entryStream) } finally { $fileStream.Dispose(); $entryStream.Dispose() }
            }
        } finally {
            $archive.Dispose()
        }
    } finally {
        if (Test-Path $temp) { Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

module Csvlint
  module Csvw
    class Table
      include Csvlint::ErrorCollector

      attr_reader :columns, :dialect, :table_direction, :foreign_keys, :foreign_key_references, :id, :notes, :primary_key, :row_title_columns, :schema, :suppress_output, :transformations, :url, :annotations

      def initialize(url, columns: [], dialect: {}, table_direction: :auto, foreign_keys: [], id: nil, notes: [], primary_key: nil, row_title_columns: [], schema: nil, suppress_output: false, transformations: [], annotations: [], warnings: [])
        @url = url
        @columns = columns
        @dialect = dialect
        @table_direction = table_direction
        @foreign_keys = foreign_keys
        @foreign_key_values = {}
        @foreign_key_references = []
        @foreign_key_reference_values = {}
        @id = id
        @notes = notes
        @primary_key = primary_key
        @primary_key_values = {}
        @row_title_columns = row_title_columns
        @schema = schema
        @suppress_output = suppress_output
        @transformations = transformations
        @annotations = annotations
        reset
        @warnings += warnings
        @errors += columns.map { |c| c.errors }.flatten
        @warnings += columns.map { |c| c.warnings }.flatten
      end

      def validate_header(headers, strict)
        reset
        headers.each_with_index do |header, i|
          if columns[i]
            columns[i].validate_header(header, strict)
            @errors += columns[i].errors
            @warnings += columns[i].warnings
          elsif strict
            build_errors(:malformed_header, :schema, 1, nil, header, nil)
          else
            build_warnings(:malformed_header, :schema, 1, nil, header, nil)
          end
        end # unless columns.empty?
        valid?
      end

      def validate_row(values, row = nil, validate = false)
        reset
        unless columns.empty?
          values.each_with_index do |value, i|
            column = columns[i]
            if column
              v = column.validate(value, row)
              values[i] = v
              @errors += column.errors
              @warnings += column.warnings
            else
              build_errors(:too_many_values, :schema, row, nil, value, nil)
            end
          end
        end
        if validate
          unless @primary_key.nil?
            key = @primary_key.map { |column| column.validate(values[column.number - 1], row) }
            colnum = primary_key.length == 1 ? primary_key[0].number : nil
            build_errors(:duplicate_key, :schema, row, colnum, key, @primary_key_values[key]) if @primary_key_values.include?(key)
            @primary_key_values[key] = row
          end
          # build a record of the unique values that are referenced by foreign keys from other tables
          # so that later we can check whether those foreign keys reference these values
          @foreign_key_references.each do |foreign_key|
            referenced_columns = foreign_key["referenced_columns"]
            key = referenced_columns.map { |column| values[column.number - 1] }
            known_values = @foreign_key_reference_values[foreign_key] = @foreign_key_reference_values[foreign_key] || {}
            known_values[key] = known_values[key] || []
            known_values[key] << row
          end
          # build a record of the references from this row to other tables
          # we can't check yet whether these exist in the other tables because
          # we might not have parsed those other tables
          @foreign_keys.each do |foreign_key|
            referencing_columns = foreign_key["referencing_columns"]
            known_values = @foreign_key_values[foreign_key] = @foreign_key_values[foreign_key] || {}
            # handle compound foreign keys and FK columns with a separator
            keys = cartesian_product_foreign_key_values(referencing_columns.map {|column| values[column.number - 1]})
            keys.each do |key|
              known_values[key] = known_values[key] || []
              # also track row number for error reporting
              known_values[key] << row
            end
          end
        end
        valid?
      end

      def cartesian_product_foreign_key_values(values)
        # If no column has a separator (no values are arrays), return [values]
        return [values] if !values.any? {|x| x.instance_of?(Array)}

        # wrap nil values in an array so we can use product()
        # otherwise it'd reduce to an empty array
        wrapped = values.map{|x| x.nil? ? [nil] : x}
        # convert first column's values to individual arrays to start the cartesian product
        # i.e. 'a' becomes [['a']], [1,2] becomes [[1],[2]]
        # then reduce + ( product + flatten ) to construct cartesian product
        # of compound + multi-value keys to foreign tables
        first = [*wrapped.shift].map{|x|[x]}
        wrapped.reduce(first){ |l,r| l.product(r).map{ |x| x.flatten } }
      end

      def validate_foreign_keys
        reset
        @foreign_keys.each do |foreign_key|
          local = @foreign_key_values[foreign_key] || {}
          next if local.nil?
          remote_table = foreign_key["referenced_table"]
          remote_table.validate_foreign_key_references(foreign_key, @url, local)
          @errors += remote_table.errors unless remote_table == self
          @warnings += remote_table.warnings unless remote_table == self
        end
        valid?
      end

      def validate_foreign_key_references(foreign_key, remote_url, remote)
        reset
        local = @foreign_key_reference_values[foreign_key] || {}
        context = {"from" => {"url" => remote_url.to_s.split("/")[-1], "columns" => foreign_key["columnReference"]}, "to" => {"url" => @url.to_s.split("/")[-1], "columns" => foreign_key["reference"]["columnReference"]}}
        colnum = foreign_key["referencing_columns"].length == 1 ? foreign_key["referencing_columns"][0].number : nil
        remote.each_key do |r|
          if local[r]
            if local[r].length > 1
              remote[r].each do |row|
                build_errors(:multiple_matched_rows, :schema, row, colnum, r, context)
              end
            end
          else
            remote[r].each do |row|
              build_errors(:unmatched_foreign_key_reference, :schema, row, colnum, r, context)
            end
          end
        end
        valid?
      end

      def self.from_json(table_desc, base_url = nil, lang = "und", common_properties = {}, inherited_properties = {})
        annotations = {}
        warnings = []
        columns = []
        table_properties = common_properties.clone
        inherited_properties = inherited_properties.clone

        table_desc.each do |property, value|
          if property == "@type"
            raise Csvlint::Csvw::MetadataError.new("$.tables[?(@.url = '#{table_desc["url"]}')].@type"), "@type of table is not 'Table'" unless value == "Table"
          else
            v, warning, type = Csvw::PropertyChecker.check_property(property, value, base_url, lang)
            warnings += Array(warning).map { |w| Csvlint::ErrorMessage.new(w, :metadata, nil, nil, "#{property}: #{value}", nil) } unless warning.nil? || warning.empty?
            if type == :annotation
              annotations[property] = v
            elsif type == :table || type == :common
              table_properties[property] = v
            elsif type == :column
              warnings << Csvlint::ErrorMessage.new(:invalid_property, :metadata, nil, nil, property.to_s, nil)
            else
              inherited_properties[property] = v
            end
          end
        end

        table_schema = table_properties["tableSchema"] || inherited_properties["tableSchema"]
        column_names = []
        foreign_keys = []
        if table_schema
          unless table_schema["columns"].instance_of? Array
            table_schema["columns"] = []
            warnings << Csvlint::ErrorMessage.new(:invalid_value, :metadata, nil, nil, "columns", nil)
          end

          table_schema.each do |p, v|
            unless ["columns", "primaryKey", "foreignKeys", "rowTitles"].include? p
              inherited_properties[p] = v
            end
          end

          virtual_columns = false
          table_schema["columns"].each_with_index do |column_desc, i|
            if column_desc.instance_of? Hash
              column = Csvlint::Csvw::Column.from_json(i + 1, column_desc, base_url, lang, inherited_properties)
              raise Csvlint::Csvw::MetadataError.new("$.tables[?(@.url = '#{table_desc["url"]}')].tableSchema.columns[#{i}].virtual"), "virtual columns before non-virtual column #{column.name || i}" if virtual_columns && !column.virtual
              virtual_columns ||= column.virtual
              raise Csvlint::Csvw::MetadataError.new("$.tables[?(@.url = '#{table_desc["url"]}')].tableSchema.columns"), "multiple columns named #{column.name}" if column_names.include? column.name
              column_names << column.name unless column.name.nil?
              columns << column
            else
              warnings << Csvlint::ErrorMessage.new(:invalid_column_description, :metadata, nil, nil, column_desc.to_s, nil)
            end
          end

          primary_key_columns = []
          primary_key_valid = true
          table_schema["primaryKey"]&.each do |reference|
            i = column_names.index(reference)
            if i
              primary_key_columns << columns[i]
            else
              warnings << Csvlint::ErrorMessage.new(:invalid_column_reference, :metadata, nil, nil, "primaryKey: #{reference}", nil)
              primary_key_valid = false
            end
          end

          foreign_keys = table_schema["foreignKeys"]
          foreign_keys&.each_with_index do |foreign_key, i|
            foreign_key_columns = []
            foreign_key["columnReference"].each do |reference|
              i = column_names.index(reference)
              raise Csvlint::Csvw::MetadataError.new("$.tables[?(@.url = '#{table_desc["url"]}')].tableSchema.foreignKeys[#{i}].columnReference"), "foreignKey references non-existant column" unless i
              foreign_key_columns << columns[i]
            end
            foreign_key["referencing_columns"] = foreign_key_columns
          end

          row_titles = table_schema["rowTitles"]
          row_title_columns = []
          row_titles&.each do |row_title|
            i = column_names.index(row_title)
            raise Csvlint::Csvw::MetadataError.new("$.tables[?(@.url = '#{table_desc["url"]}')].tableSchema.rowTitles[#{i}]"), "rowTitles references non-existant column" unless i
            row_title_columns << columns[i]
          end

        end

        new(table_properties["url"],
          id: table_properties["@id"],
          columns: columns,
          dialect: table_properties["dialect"],
          foreign_keys: foreign_keys || [],
          notes: table_properties["notes"] || [],
          primary_key: primary_key_valid && !primary_key_columns.empty? ? primary_key_columns : nil,
          row_title_columns: row_title_columns,
          schema: table_schema ? table_schema["@id"] : nil,
          suppress_output: table_properties["suppressOutput"] || false,
          annotations: annotations,
          warnings: warnings)
      end
    end
  end
end

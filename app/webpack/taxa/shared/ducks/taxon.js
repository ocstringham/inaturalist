import inatjs from "inaturalistjs";
import moment from "moment";
import querystring from "querystring";
import _ from "lodash";
import { fetch, defaultObservationParams } from "../../shared/util";

const SET_TAXON = "taxa-show/taxon/SET_TAXON";
const SET_DESCRIPTION = "taxa-show/taxon/SET_DESCRIPTION";
const SET_LINKS = "taxa-show/taxon/SET_LINKS";
const SET_COUNT = "taxa-show/taxon/SET_COUNT";
const SET_NAMES = "taxa-show/taxon/SET_NAMES";
const SET_INTERACTIONS = "taxa-show/taxon/SET_INTERACTIONS";
const SET_TRENDING = "taxa-show/taxon/SET_TRENDING";
const SET_RARE = "taxa-show/taxon/SET_RARE";
const SET_SIMILAR = "taxa-show/taxon/SET_SIMILAR";
const SHOW_PHOTO_CHOOSER = "taxa-show/taxon/SHOW_PHOTO_CHOOSER";
const HIDE_PHOTO_CHOOSER = "taxa-show/taxon/HIDE_PHOTO_CHOOSER";

export default function reducer( state = { counts: {} }, action ) {
  const newState = Object.assign( { }, state );
  switch ( action.type ) {
    case SET_TAXON:
      newState.taxon = action.taxon;
      newState.taxonPhotos = _.uniqBy( newState.taxon.taxonPhotos, tp => tp.photo.id );
      // HACK until we get controlled terms working.
      newState.terms = [];
      if ( newState.taxon.iconic_taxon_name === "Insecta" ) {
        newState.terms.push( {
          name: "Insect life stage",
          values: [
            "adult",
            "teneral",
            "pupa",
            "nymph",
            "larva",
            "egg"
          ]
        } );
      }
      if (
        newState.taxon &&
        _.find( newState.taxon.ancestors, a => a.name === "Magnoliophyta" )
      ) {
        newState.terms.push( {
          name: "Flowering Phenology",
          values: [
            "bare",
            "budding",
            "flower",
            "fruit"
          ]
        } );
      }
      // END HACK
      break;
    case SET_DESCRIPTION:
      newState.description = {
        source: action.source,
        url: action.url,
        body: action.body
      };
      break;
    case SET_LINKS:
      newState.links = action.links;
      break;
    case SET_COUNT:
      newState.counts = state.counts || {};
      newState.counts[action.count] = action.value;
      break;
    case SET_NAMES:
      newState.names = action.names;
      break;
    case SET_INTERACTIONS:
      newState.interactions = action.interactions;
      break;
    case SET_TRENDING:
      newState.trending = action.taxa;
      break;
    case SET_RARE:
      newState.rare = action.taxa;
      break;
    case SET_SIMILAR:
      newState.similar = action.taxa;
      break;
    case SHOW_PHOTO_CHOOSER:
      newState.photoChooserVisible = true;
      break;
    case HIDE_PHOTO_CHOOSER:
      newState.photoChooserVisible = false;
      break;
    default:
      // nothing to see here
  }
  return newState;
}

export function setTaxon( taxon ) {
  return {
    type: SET_TAXON,
    taxon
  };
}

export function setDescription( source, url, body ) {
  return {
    type: SET_DESCRIPTION,
    source,
    url,
    body
  };
}

export function setLinks( links ) {
  return {
    type: SET_LINKS,
    links
  };
}

export function setCount( count, value ) {
  return {
    type: SET_COUNT,
    count,
    value
  };
}

export function setNames( names ) {
  return {
    type: SET_NAMES,
    names
  };
}

export function setInteractions( interactions ) {
  return {
    type: SET_INTERACTIONS,
    interactions
  };
}

export function setTrending( taxa ) {
  return {
    type: SET_TRENDING,
    taxa
  };
}

export function setRare( taxa ) {
  return {
    type: SET_RARE,
    taxa
  };
}

export function setSimilar( taxa ) {
  return {
    type: SET_SIMILAR,
    taxa
  };
}

export function showPhotoChooser( ) {
  return { type: SHOW_PHOTO_CHOOSER };
}

export function hidePhotoChooser( ) {
  return { type: HIDE_PHOTO_CHOOSER };
}

export function showPhotoChooserIfSignedIn( ) {
  return ( dispatch, getState ) => {
    const currentUser = getState( ).config.currentUser;
    const signedIn = currentUser && currentUser.id;
    if ( signedIn ) {
      dispatch( showPhotoChooser( ) );
    } else {
      window.location = `/login?return_to=${window.location}`;
    }
  };
}

export function fetchTaxon( taxon, options = { } ) {
  return ( dispatch, getState ) => {
    const s = getState( );
    const t = taxon || s.taxon.taxon;
    const params = Object.assign( { }, options, {
      preferred_place_id: s.config.preferredPlace ? s.config.preferredPlace.id : null
    } );
    return inatjs.taxa.fetch( t.id, params ).then( response => {
      dispatch( setTaxon( response.results[0] ) );
    } );
  };
}

export function fetchDescription( ) {
  return ( dispatch, getState ) => {
    const taxon = getState( ).taxon.taxon;
    fetch( `/taxa/${taxon.id}/description` ).then(
      response => {
        const source = response.headers.get( "X-Describer-Name" );
        const url = response.headers.get( "X-Describer-URL" );
        response.text( ).then(
          body => dispatch( setDescription( source, url, body )
        ) );
      },
      error => {
        console.log( "[DEBUG] error: ", error );
      }
    );
  };
}

export function fetchLinks( ) {
  return ( dispatch, getState ) => {
    const taxon = getState( ).taxon.taxon;
    fetch( `/taxa/${taxon.id}/links.json` ).then(
      response => {
        response.json( ).then( json => dispatch( setLinks( json ) ) );
      },
      error => {
        console.log( "[DEBUG] error: ", error );
      }
    );
  };
}

export function fetchNames( taxon ) {
  return ( dispatch, getState ) => {
    const t = taxon || getState( ).taxon.taxon;
    fetch( `/taxon_names.json?taxon_id=${t.id}` ).then(
      response => {
        response.json( ).then( json => dispatch( setNames( json ) ) );
      },
      error => {
        console.log( "[DEBUG] error: ", error );
      }
    );
  };
}

export function fetchInteractions( taxon ) {
  return ( dispatch, getState ) => {
    const t = taxon || getState( ).taxon.taxon;
    const params = {
      sourceTaxon: t.name,
      type: "json.v2",
      accordingTo: "iNaturalist"
    };
    const url = `http://api.globalbioticinteractions.org/interaction?${querystring.stringify( params )}`;
    fetch( url ).then(
      response => {
        response.json( ).then( json => dispatch( setInteractions( json ) ) );
      },
      error => {
        console.log( "[DEBUG] error: ", error );
      }
    );
  };
}

export function fetchTrending( ) {
  return ( dispatch, getState ) => {
    const params = Object.assign( { }, defaultObservationParams( getState( ) ), {
      d1: moment( ).subtract( 1, "month" ).format( "YYYY-MM-DD" )
    } );
    inatjs.observations.speciesCounts( params ).then(
      response =>
        dispatch( setTrending( response.results.map( r => r.taxon ) ) ),
      error => {
        console.log( "[DEBUG] error: ", error );
      }
    );
  };
}

export function fetchRare( ) {
  return ( dispatch, getState ) => {
    const params = Object.assign( { }, defaultObservationParams( getState( ) ), {
      order: "asc"
    } );
    inatjs.observations.speciesCounts( params ).then(
      response =>
        dispatch( setRare( response.results.map( r => r.taxon ) ) ),
      error => {
        console.log( "[DEBUG] error: ", error );
      }
    );
  };
}

export function fetchSimilar( ) {
  return ( dispatch, getState ) => {
    const params = { taxon_id: getState( ).taxon.taxon.id };
    inatjs.identifications.similar_species( params ).then(
      response => dispatch( setSimilar( response.results.map( r => r.taxon ) ) ),
      error => console.log( "[DEBUG] error: ", error )
    );
  };
}

export function updatePhotos( photos ) {
  return ( dispatch, getState ) => {
    const s = getState( );
    const taxon = s.taxon.taxon;
    const data = { };
    data.photos = photos.map( photo => ( {
      id: photo.id,
      type: photo.type,
      native_photo_id: photo.native_photo_id
    } ) );
    data.authenticity_token = $( "meta[name=csrf-token]" ).attr( "content" );
    const params = {
      method: "POST",
      headers: {
        "Content-Type": "application/json"
      },
      body: JSON.stringify( data )
    };
    fetch( `/taxa/${taxon.id}/set_photos.json`, params )
      .then( ( ) => {
        dispatch( fetchTaxon( s.taxon.taxon, { ttl: -1 } ) );
        dispatch( hidePhotoChooser( ) );
      } );
  };
}
